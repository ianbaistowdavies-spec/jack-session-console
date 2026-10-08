// Captures "what you hear" or one app's audio.
// This FFmpeg build has no WASAPI device, so the mix is done here and
// handed to FFmpeg as 48 kHz stereo 16-bit PCM.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

public class JackAppItem {
    public int Pid;
    public string Exe;
    public string Label;
    public bool HasAudio;
    public override string ToString() {
        return HasAudio ? Label + "  (playing)" : Label;
    }
}

public class JackDeskAudio {
    public string Warning { get; private set; }

    Stream pcm;
    Thread thread;
    volatile bool running;
    readonly List<string> problems = new List<string>();

    public static JackAppItem[] ListApps() {
        var groups = new Dictionary<string, AppGroup>(StringComparer.OrdinalIgnoreCase);
        EnumWindows((h, l) => {
            try {
                if (!IsWindowVisible(h)) return true;
                var title = new System.Text.StringBuilder(512);
                if (GetWindowText(h, title, title.Capacity) <= 0) return true;
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (pid == 0) return true;
                AddPid(groups, (int)pid, false);
            } catch { }
            return true;
        }, IntPtr.Zero);

        var list = new List<AppGroup>(groups.Values);
        list.Sort((a, b) => {
            int c = b.HasAudio.CompareTo(a.HasAudio);
            if (c != 0) return c;
            return string.Compare(a.Label, b.Label, StringComparison.OrdinalIgnoreCase);
        });
        var items = new JackAppItem[list.Count];
        for (int i = 0; i < list.Count; i++) {
            items[i] = new JackAppItem {
                Pid = list[i].RootPid,
                Exe = list[i].Exe,
                Label = list[i].Label,
                HasAudio = list[i].HasAudio
            };
        }
        return items;
    }

    // allPcAudio mixes every active playback device. Otherwise pids are app roots.
    // Returns an error message, or null when capture is running.
    public string Start(Stream destination, bool allPcAudio, int[] pids) {
        if (destination == null) return "No audio output stream.";
        if (!allPcAudio && (pids == null || pids.Length == 0))
            return "Tick at least one app, or choose All PC audio.";
        pcm = destination;
        running = true;
        string error = null;
        var ready = new ManualResetEvent(false);
        thread = new Thread(() => {
            int com = CoInitializeEx(IntPtr.Zero, 0);
            var sources = new List<CapSource>();
            try {
                try {
                    if (allPcAudio) OpenAllDevices(sources);
                    else OpenProcesses(sources, pids);
                    if (sources.Count == 0) {
                        error = problems.Count > 0
                            ? string.Join(" ", problems.ToArray())
                            : "Could not open any audio source.";
                    } else if (problems.Count > 0) {
                        Warning = string.Join(" ", problems.ToArray());
                    }
                } catch (Exception ex) {
                    error = ex.Message;
                }
                ready.Set();
                if (error != null || sources.Count == 0) return;
                MixLoop(sources);
            } finally {
                if (com == 0) CoUninitialize();
            }
        });
        thread.IsBackground = true;
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        if (!ready.WaitOne(8000)) return "Audio capture did not start in time.";
        return error;
    }

    public void Stop() {
        running = false;
        if (thread == null) return;
        if (!thread.Join(2500)) {
            try { if (pcm != null) pcm.Close(); } catch { }
            thread.Join(1500);
        }
        thread = null;
    }

    void MixLoop(List<CapSource> sources) {
        var block = new short[480 * 2]; // 10 ms at 48 kHz stereo
        var bytes = new byte[block.Length * 2];
        var watch = Stopwatch.StartNew();
        long next = 0;
        try {
            while (running) {
                for (int i = 0; i < sources.Count; i++) sources[i].Drain();
                long now = watch.ElapsedMilliseconds;
                if (now < next) {
                    Thread.Sleep(2);
                    continue;
                }
                while (running && now >= next) {
                    Array.Clear(block, 0, block.Length);
                    for (int i = 0; i < sources.Count; i++) sources[i].Queue.MixInto(block);
                    Buffer.BlockCopy(block, 0, bytes, 0, bytes.Length);
                    pcm.Write(bytes, 0, bytes.Length);
                    next += 10;
                    now = watch.ElapsedMilliseconds;
                    if (next < now - 200) next = now;
                }
            }
        } catch (Exception) {
            running = false;
        } finally {
            for (int i = 0; i < sources.Count; i++) sources[i].Close();
            try { pcm.Flush(); } catch { }
        }
    }

    void OpenAllDevices(List<CapSource> sources) {
        var devices = PlaybackDevices();
        if (devices.Count == 0) {
            CapSource fallback;
            string err = OpenEndpoint("{E6327CAD-DCEC-4949-AE8A-991E976A79D2}", "default playback", out fallback);
            if (err != null) problems.Add(err);
            else sources.Add(fallback);
        }
        for (int i = 0; i < devices.Count; i++) {
            CapSource src;
            string err = OpenEndpoint(devices[i].Path, devices[i].Name, out src);
            if (err != null) problems.Add(err);
            else sources.Add(src);
        }
        if (sources.Count == 0 && problems.Count == 0)
            problems.Add("No playback device could be captured.");
    }

    class PlaybackDevice {
        public string Path;
        public string Name;
    }

    static List<PlaybackDevice> PlaybackDevices() {
        var list = new List<PlaybackDevice>();
        try {
            using (var root = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                @"SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render")) {
                if (root == null) return list;
                foreach (string id in root.GetSubKeyNames()) {
                    using (var dev = root.OpenSubKey(id)) {
                        if (dev == null) continue;
                        object state = dev.GetValue("DeviceState");
                        if (!(state is int) || (int)state != 1) continue;
                        string desc = null;
                        string iface = null;
                        using (var props = dev.OpenSubKey("Properties")) {
                            if (props != null) {
                                desc = props.GetValue("{a45c254e-df1c-4efd-8020-67d146a850e0},2") as string;
                                iface = props.GetValue("{b3f8fa53-0004-438e-9003-51a46e139bfc},6") as string;
                            }
                        }
                        string name = string.IsNullOrEmpty(desc) ? "Playback" : desc;
                        if (!string.IsNullOrEmpty(iface) && !name.Equals(iface, StringComparison.OrdinalIgnoreCase))
                            name = name + " (" + iface + ")";
                        list.Add(new PlaybackDevice {
                            Name = name,
                            Path = @"\\?\SWD#MMDEVAPI#{0.0.0.00000000}." + id + "#{e6327cad-dcec-4949-ae8a-991e976a79d2}"
                        });
                    }
                }
            }
        } catch { }
        return list;
    }

    void OpenProcesses(List<CapSource> sources, int[] pids) {
        var seen = new HashSet<int>();
        for (int i = 0; i < pids.Length; i++) {
            int root = AppRoot(pids[i]);
            if (root <= 0 || !seen.Add(root)) continue;
            string name = ProcessName(root);
            CapSource src;
            string err = OpenProcessLoopback(root, string.IsNullOrEmpty(name) ? ("pid " + root) : name, out src);
            if (err != null) problems.Add(err);
            else sources.Add(src);
        }
    }

    static string OpenEndpoint(string devicePath, string name, out CapSource src) {
        src = null;
        var handler = new ActivateHandler();
        Guid iid = IID_IAudioClient;
        IActivateAudioInterfaceAsyncOperation op;
        int hr = ActivateAudioInterfaceAsync(devicePath, iid, IntPtr.Zero, handler, out op);
        if (hr != 0) return "Could not open " + name + " (" + Hex(hr) + ").";
        if (!handler.Done.WaitOne(5000)) return "Could not open " + name + " (timed out).";
        if (handler.Hr != 0 || handler.Client == null)
            return "Could not open " + name + " (" + Hex(handler.Hr) + ").";
        return FinishOpen(handler.Client, name, out src);
    }

    static string OpenProcessLoopback(int pid, string name, out CapSource src) {
        src = null;
        var activation = new AudioClientActivationParams();
        activation.ActivationType = 1;
        activation.TargetProcessId = (uint)pid;
        activation.ProcessLoopbackMode = 0;
        int blobSize = Marshal.SizeOf(typeof(AudioClientActivationParams));
        IntPtr blob = Marshal.AllocHGlobal(blobSize);
        IntPtr pv = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(BlobPropVariant)));
        try {
            Marshal.StructureToPtr(activation, blob, false);
            var variant = new BlobPropVariant();
            variant.vt = 65; // VT_BLOB
            variant.cbSize = (uint)blobSize;
            variant.pBlobData = blob;
            Marshal.StructureToPtr(variant, pv, false);

            var handler = new ActivateHandler();
            Guid iid = IID_IAudioClient;
            IActivateAudioInterfaceAsyncOperation op;
            int hr = ActivateAudioInterfaceAsync("VAD\\Process_Loopback", iid, pv, handler, out op);
            if (hr != 0) return "Could not capture " + name + " (" + Hex(hr) + ").";
            if (!handler.Done.WaitOne(5000)) return "Could not capture " + name + " (timed out).";
            if (handler.Hr != 0 || handler.Client == null)
                return "Could not capture " + name + " (" + Hex(handler.Hr) + ").";
            return FinishOpen(handler.Client, name, out src);
        } finally {
            Marshal.FreeHGlobal(blob);
            Marshal.FreeHGlobal(pv);
        }
    }

    static string FinishOpen(IAudioClient client, string name, out CapSource src) {
        src = null;
        int channels = 2;
        int bits = 16;
        bool isFloat = false;
        IntPtr fmt = FormatPcm48();
        bool mixMem = false;
        try {
            // LOOPBACK | AUTOCONVERTPCM | SRC_DEFAULT_QUALITY. 16-bit 48 kHz out.
            const uint flags = 0x00020000 | 0x80000000 | 0x08000000;
            int hr = client.Initialize(0, flags, 0, 0, fmt, IntPtr.Zero);
            if (hr == unchecked((int)0x88890008)) {
                Marshal.FreeHGlobal(fmt);
                fmt = IntPtr.Zero;
                int mhr = client.GetMixFormat(out fmt);
                if (mhr != 0 || fmt == IntPtr.Zero)
                    return "Could not start " + ShortName(name) + " (" + Hex(hr) + ").";
                mixMem = true;
                int rate;
                if (!ReadFormat(fmt, out channels, out bits, out isFloat, out rate))
                    return "Could not start " + ShortName(name) + " (" + Hex(hr) + ").";
                if (rate != 48000)
                    return "Could not start " + ShortName(name) + " (it is not 48 kHz).";
                hr = client.Initialize(0, 0x00020000, 0, 0, fmt, IntPtr.Zero);
            }
            if (hr != 0) return "Could not start " + ShortName(name) + " (" + Hex(hr) + ").";
        } finally {
            if (fmt != IntPtr.Zero) {
                if (mixMem) Marshal.FreeCoTaskMem(fmt);
                else Marshal.FreeHGlobal(fmt);
            }
        }
        Guid capId = IID_IAudioCaptureClient;
        object svc;
        int ghr = client.GetService(ref capId, out svc);
        var capture = svc as IAudioCaptureClient;
        if (ghr != 0 || capture == null) return "Could not read " + ShortName(name) + " (" + Hex(ghr) + ").";
        int shr = client.Start();
        if (shr != 0) return "Could not start " + ShortName(name) + " (" + Hex(shr) + ").";
        src = new CapSource();
        src.Client = client;
        src.Capture = capture;
        src.Name = name;
        src.Channels = channels;
        src.Bits = bits;
        src.Float = isFloat;
        return null;
    }

    static bool ReadFormat(IntPtr fmt, out int channels, out int bits, out bool isFloat, out int rate) {
        channels = 2;
        bits = 16;
        isFloat = false;
        rate = 0;
        if (fmt == IntPtr.Zero) return false;
        int tag = Marshal.ReadInt16(fmt, 0);
        channels = Marshal.ReadInt16(fmt, 2);
        rate = Marshal.ReadInt32(fmt, 4);
        bits = Marshal.ReadInt16(fmt, 14);
        if (tag == 3) isFloat = true;
        else if (tag == 0xFFFE) {
            var sub = new byte[16];
            Marshal.Copy(IntPtr.Add(fmt, 24), sub, 0, 16);
            var kind = new Guid(sub);
            isFloat = kind == new Guid("00000003-0000-0010-8000-00aa00389b71");
            bool pcm = kind == new Guid("00000001-0000-0010-8000-00aa00389b71");
            if (!isFloat && !pcm) return false;
        } else if (tag != 1) {
            return false;
        }
        if (channels < 1 || channels > 2) return false;
        if (isFloat && bits != 32) return false;
        if (!isFloat && bits != 16) return false;
        return true;
    }

    static void AddPid(Dictionary<string, AppGroup> groups, int pid, bool hasAudio) {
        if (pid <= 4) return;
        int root = AppRoot(pid);
        if (root <= 0) return;
        string path = ExePath(root);
        string proc = ProcessName(root);
        if (string.IsNullOrEmpty(proc) || SkipName(proc)) return;
        string key = string.IsNullOrEmpty(path) ? proc : path;
        AppGroup group;
        if (!groups.TryGetValue(key, out group)) {
            group = new AppGroup();
            group.RootPid = root;
            group.Exe = string.IsNullOrEmpty(path) ? proc + ".exe" : Path.GetFileName(path);
            group.Label = LabelFor(root, path, proc);
            groups[key] = group;
        }
        if (hasAudio) group.HasAudio = true;
    }

    static string LabelFor(int pid, string path, string proc) {
        string desc = null;
        if (!string.IsNullOrEmpty(path)) {
            try {
                string fileDesc = FileVersionInfo.GetVersionInfo(path).FileDescription;
                if (!string.IsNullOrEmpty(fileDesc)) desc = fileDesc.Trim();
            } catch { }
        }
        if (string.IsNullOrEmpty(desc)) desc = proc;
        string title = null;
        try { title = Process.GetProcessById(pid).MainWindowTitle; } catch { }
        if (!string.IsNullOrEmpty(title)) {
            title = title.Trim();
            if (title.Length > 48) title = title.Substring(0, 48);
            if (!desc.Equals(title, StringComparison.OrdinalIgnoreCase)) return desc + " - " + title;
        }
        return desc;
    }

    static bool SkipName(string name) {
        switch (name.ToLowerInvariant()) {
            case "explorer":
            case "svchost":
            case "dwm":
            case "csrss":
            case "lsass":
            case "services":
            case "wininit":
            case "winlogon":
            case "fontdrvhost":
            case "sihost":
            case "ctfmon":
            case "runtimebroker":
            case "applicationframehost":
            case "textinputhost":
            case "systemsettings":
            case "shellexperiencehost":
            case "searchhost":
            case "startmenuexperiencehost":
            case "lockapp":
            case "audiodg":
            case "conhost":
            case "dllhost":
            case "backgroundtaskhost":
            case "searchindexer":
            case "securityhealthsystray":
            case "securityhealthservice":
            case "widgets":
            case "widgetboard":
            case "gamebar":
            case "gamebarftserver":
            case "ffmpeg":
            case "idle":
            case "system":
            case "registry":
            case "smss":
            case "taskhostw":
            case "spoolsv":
            case "msmpeng":
            case "nissrv":
            case "wmiprvse":
            case "unsecapp":
            case "powershell":
            case "pwsh":
            case "openconsole":
            case "windowsterminal":
                return true;
            default:
                return false;
        }
    }

    static int AppRoot(int pid) {
        int cur = pid;
        string curPath = ExePath(cur);
        for (int n = 0; n < 8; n++) {
            int parent = ParentPid(cur);
            if (parent <= 0 || parent == cur) break;
            string parentPath = ExePath(parent);
            if (string.IsNullOrEmpty(parentPath) || string.IsNullOrEmpty(curPath)) break;
            if (!parentPath.Equals(curPath, StringComparison.OrdinalIgnoreCase)) break;
            cur = parent;
            curPath = parentPath;
        }
        return cur;
    }

    static int ParentPid(int pid) {
        IntPtr h = OpenProcess(0x1000, false, pid);
        if (h == IntPtr.Zero) return 0;
        try {
            var info = new ProcessBasicInfo();
            int ret;
            int status = NtQueryInformationProcess(h, 0, ref info, Marshal.SizeOf(typeof(ProcessBasicInfo)), out ret);
            if (status != 0) return 0;
            return info.InheritedFromUniqueProcessId.ToInt32();
        } finally { CloseHandle(h); }
    }

    static string ExePath(int pid) {
        try { return Process.GetProcessById(pid).MainModule.FileName; }
        catch { return null; }
    }

    static string ProcessName(int pid) {
        try { return Process.GetProcessById(pid).ProcessName; }
        catch { return null; }
    }

    static IntPtr FormatPcm48() {
        var fmt = new WaveFormatEx();
        fmt.FormatTag = 1;
        fmt.Channels = 2;
        fmt.SamplesPerSec = 48000;
        fmt.BitsPerSample = 16;
        fmt.BlockAlign = 4;
        fmt.AvgBytesPerSec = 192000;
        fmt.Extra = 0;
        IntPtr p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(WaveFormatEx)));
        Marshal.StructureToPtr(fmt, p, false);
        return p;
    }

    static string Hex(int hr) { return "0x" + hr.ToString("X8"); }

    static string ShortName(string name) {
        if (string.IsNullOrEmpty(name)) return "audio";
        int slash = name.LastIndexOf('\\');
        if (slash >= 0 && slash < name.Length - 1) name = name.Substring(slash + 1);
        if (name.Length > 48) name = name.Substring(0, 48);
        return name;
    }

    class AppGroup {
        public int RootPid;
        public string Exe;
        public string Label;
        public bool HasAudio;
    }

    class SampleQueue {
        readonly short[] data = new short[48000 * 2];
        int read;
        int count;
        public void Add(short[] src, int n) {
            if (n <= 0) return;
            if (n > data.Length) {
                src = Shift(src, n - data.Length, data.Length);
                n = data.Length;
            }
            int over = count + n - data.Length;
            if (over > 0) {
                read += over;
                if (read >= data.Length) read -= data.Length;
                count -= over;
            }
            for (int i = 0; i < n; i++) {
                int at = read + count;
                if (at >= data.Length) at -= data.Length;
                data[at] = src[i];
                count++;
            }
        }
        static short[] Shift(short[] src, int skip, int take) {
            var dst = new short[take];
            Array.Copy(src, skip, dst, 0, take);
            return dst;
        }
        public void MixInto(short[] dest) {
            int take = dest.Length;
            if (take > count) take = count;
            for (int i = 0; i < take; i++) {
                int sum = dest[i] + data[read];
                if (sum > short.MaxValue) sum = short.MaxValue;
                else if (sum < short.MinValue) sum = short.MinValue;
                dest[i] = (short)sum;
                read++;
                if (read >= data.Length) read = 0;
                count--;
            }
        }
    }

    class CapSource {
        public IAudioClient Client;
        public IAudioCaptureClient Capture;
        public SampleQueue Queue = new SampleQueue();
        public string Name;
        public int Channels = 2;
        public int Bits = 16;
        public bool Float;
        short[] scratch = new short[4096];
        float[] floatScratch = new float[0];
        public void Drain() {
            if (Capture == null) return;
            try {
                int packet;
                while (Capture.GetNextPacketSize(out packet) == 0 && packet > 0) {
                    IntPtr data;
                    int frames, flags;
                    long devPos, qpc;
                    if (Capture.GetBuffer(out data, out frames, out flags, out devPos, out qpc) != 0) break;
                    int n = frames * 2;
                    if (n > scratch.Length) scratch = new short[n];
                    bool silent = (flags & 2) != 0 || data == IntPtr.Zero || frames <= 0;
                    if (silent) {
                        Array.Clear(scratch, 0, n);
                    } else if (Float) {
                        int raw = frames * Channels;
                        if (floatScratch.Length < raw) floatScratch = new float[raw];
                        Marshal.Copy(data, floatScratch, 0, raw);
                        if (Channels == 1) {
                            for (int i = 0; i < frames; i++) {
                                short s = FloatToShort(floatScratch[i]);
                                scratch[i * 2] = s;
                                scratch[i * 2 + 1] = s;
                            }
                        } else {
                            for (int i = 0; i < raw; i++) scratch[i] = FloatToShort(floatScratch[i]);
                        }
                    } else if (Channels == 1) {
                        int raw = frames;
                        var mono = new short[raw];
                        Marshal.Copy(data, mono, 0, raw);
                        for (int i = 0; i < frames; i++) {
                            scratch[i * 2] = mono[i];
                            scratch[i * 2 + 1] = mono[i];
                        }
                    } else {
                        Marshal.Copy(data, scratch, 0, n);
                    }
                    Capture.ReleaseBuffer(frames);
                    if (n > 0) Queue.Add(scratch, n);
                }
            } catch { Capture = null; }
        }
        static short FloatToShort(float v) {
            if (v > 1f) v = 1f;
            else if (v < -1f) v = -1f;
            return (short)(v * 32767f);
        }
        public void Close() {
            try { if (Client != null) Client.Stop(); } catch { }
            Client = null;
            Capture = null;
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct WaveFormatEx {
        public ushort FormatTag;
        public ushort Channels;
        public uint SamplesPerSec;
        public uint AvgBytesPerSec;
        public ushort BlockAlign;
        public ushort BitsPerSample;
        public ushort Extra;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct AudioClientActivationParams {
        public int ActivationType;
        public uint TargetProcessId;
        public int ProcessLoopbackMode;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct BlobPropVariant {
        public ushort vt;
        public ushort r1;
        public ushort r2;
        public ushort r3;
        public uint cbSize;
        public IntPtr pBlobData;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ProcessBasicInfo {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    static readonly Guid IID_IAudioClient = new Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2");
    static readonly Guid IID_IAudioCaptureClient = new Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317");
    static readonly Guid IID_IAudioSessionManager2 = new Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    [DllImport("ole32.dll")] static extern int CoInitializeEx(IntPtr reserved, uint coInit);
    [DllImport("ole32.dll")] static extern void CoUninitialize();
    [DllImport("Mmdevapi.dll", ExactSpelling = true, PreserveSig = true)]
    static extern int ActivateAudioInterfaceAsync(
        [MarshalAs(UnmanagedType.LPWStr)] string deviceInterfacePath,
        [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        IntPtr activationParams,
        IActivateAudioInterfaceCompletionHandler handler,
        out IActivateAudioInterfaceAsyncOperation operation);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("ntdll.dll")]
    static extern int NtQueryInformationProcess(IntPtr proc, int cls, ref ProcessBasicInfo info, int len, out int ret);
    delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int GetWindowText(IntPtr hWnd, System.Text.StringBuilder text, int max);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
}

[ComImport, Guid("00000001-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IClassFactory {
    [PreserveSig] int CreateInstance(IntPtr outer, ref Guid riid, [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
    [PreserveSig] int LockServer([MarshalAs(UnmanagedType.Bool)] bool fLock);
}

[ComImport, Guid("BCDE0395-E52E-467C-8E3D-C4579291692E")]
public class JackMMDeviceEnumerator { }

[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceEnumerator {
    [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
    [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
    [PreserveSig] int GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
    [PreserveSig] int RegisterEndpointNotificationCallback(IntPtr client);
    [PreserveSig] int UnregisterEndpointNotificationCallback(IntPtr client);
}

[ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDeviceCollection {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int Item(int index, out IMMDevice device);
}

[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IMMDevice {
    [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object instance);
    [PreserveSig] int OpenPropertyStore(int access, out IJackPropertyStore store);
    [PreserveSig] int GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetState(out int state);
}

[ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IJackPropertyStore {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetAt(int index, IntPtr key);
    [PreserveSig] int GetValue(IntPtr key, IntPtr value);
    [PreserveSig] int SetValue(IntPtr key, IntPtr value);
    [PreserveSig] int Commit();
}

[ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioClient {
    [PreserveSig] int Initialize(int shareMode, uint streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
    [PreserveSig] int GetBufferSize(out uint frames);
    [PreserveSig] int GetStreamLatency(out long latency);
    [PreserveSig] int GetCurrentPadding(out uint padding);
    [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
    [PreserveSig] int GetMixFormat(out IntPtr format);
    [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minPeriod);
    [PreserveSig] int Start();
    [PreserveSig] int Stop();
    [PreserveSig] int Reset();
    [PreserveSig] int SetEventHandle(IntPtr handle);
    [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
}

[ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioCaptureClient {
    [PreserveSig] int GetBuffer(out IntPtr data, out int frames, out int flags, out long devicePosition, out long qpcPosition);
    [PreserveSig] int ReleaseBuffer(int frames);
    [PreserveSig] int GetNextPacketSize(out int frames);
}

[ComImport, Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionManager2 {
    [PreserveSig] int GetAudioSessionControl(IntPtr guid, int flags, out IntPtr session);
    [PreserveSig] int GetSimpleAudioVolume(IntPtr guid, int flags, out IntPtr volume);
    [PreserveSig] int GetSessionEnumerator(out IAudioSessionEnumerator enumerator);
    [PreserveSig] int RegisterSessionNotification(IntPtr notification);
    [PreserveSig] int UnregisterSessionNotification(IntPtr notification);
    [PreserveSig] int RegisterDuckNotification(IntPtr sessionId, IntPtr notification);
    [PreserveSig] int UnregisterDuckNotification(IntPtr notification);
}

[ComImport, Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionEnumerator {
    [PreserveSig] int GetCount(out int count);
    [PreserveSig] int GetSession(int index, out IAudioSessionControl2 session);
}

[ComImport, Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAudioSessionControl2 {
    [PreserveSig] int GetState(out int state);
    [PreserveSig] int GetDisplayName([MarshalAs(UnmanagedType.LPWStr)] out string name);
    [PreserveSig] int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string name, IntPtr context);
    [PreserveSig] int GetIconPath([MarshalAs(UnmanagedType.LPWStr)] out string path);
    [PreserveSig] int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string path, IntPtr context);
    [PreserveSig] int GetGroupingParam(out Guid grouping);
    [PreserveSig] int SetGroupingParam(ref Guid grouping, IntPtr context);
    [PreserveSig] int RegisterAudioSessionNotification(IntPtr notification);
    [PreserveSig] int UnregisterAudioSessionNotification(IntPtr notification);
    [PreserveSig] int GetSessionIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetSessionInstanceIdentifier([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int GetProcessId(out int pid);
    [PreserveSig] int IsSystemSoundsSession();
    [PreserveSig] int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
}

[ComImport, Guid("41D949AB-9862-444A-80F6-C261334DA5EB"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IActivateAudioInterfaceCompletionHandler {
    void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation);
}

[ComImport, Guid("72A22D78-CDE4-431D-B8CC-843A71199B6D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IActivateAudioInterfaceAsyncOperation {
    [PreserveSig] int GetActivateResult(out int activateResult, [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
}

[ComImport, Guid("94EA2B94-E9CC-49E0-C0FF-EE64CA8F5B90"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IAgileObject { }

[ComVisible(true)]
[ClassInterface(ClassInterfaceType.None)]
public class ActivateHandler : IActivateAudioInterfaceCompletionHandler, IAgileObject {
    public int Hr = unchecked((int)0x80004005);
    public IAudioClient Client;
    public readonly ManualResetEvent Done = new ManualResetEvent(false);
    public void ActivateCompleted(IActivateAudioInterfaceAsyncOperation operation) {
        try {
            int activateHr;
            object punk;
            int outer = operation.GetActivateResult(out activateHr, out punk);
            Hr = outer != 0 ? outer : activateHr;
            Client = punk as IAudioClient;
        } catch (Exception) {
            Hr = unchecked((int)0x80004005);
        }
        Done.Set();
    }
}
