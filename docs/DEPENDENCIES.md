# Jack Session Console — dependencies

This is the install ledger for **Jack’s Windows gaming PC**. The installer (`install/Install-JackConsole.ps1`) is required to **install or verify every required item** and to **refuse Ready** if recording cannot actually start.

Fail-loud applies to setup the same way it applies to capture: a half-installed box must not look like a working recorder, and it must not be allowed to publish.

## Docker wrapping: no

**Do not wrap the recorder, the preview proxy, or the Android link in Docker.**

| Layer | Docker? | Why |
|---|---|---|
| Game / webcam / mic capture | **No** | Needs to hook the **host** game, WASAPI loopback, and USB camera. Windows containers and WSL2 cannot do Game Capture on a fullscreen title. |
| NVENC while Jack is in-game | **No** | Encoder must be the host driver’s NVENC. Docker GPU-PV on Windows is a WSL compute path, extra RAM, extra copies. |
| Live / proxy preview | **No** | Extra process hops steal the ~2 GB VRAM budget. |
| Companion API (LAN) | **No** | A tiny native HTTP listener is enough. Docker Desktop is a resident hog on a gaming PC. |
| Offline AI / scene detect | After the game, on Jack | Game closed → his 8 GB is free. Do not offload to Ian's GPU. Gateway is parked; see `docs/GATEWAY.md`. |

Docker Desktop also pulls in WSL2, a VM, and a background GPU/RAM footprint. That fights the “game owns ~6 GB of 8 GB” rule.

**Install rule:** Docker is in `forbidden_as_required`. The bootstrapper must not install it and must not need it.

What we use instead: a **native Windows capture service** plus **winget** for runtimes, with an **atomic Ready flag** written only after preflight.

## What gets installed on Jack’s PC

Source of truth: `install/dependencies.json`.

### Required (installer must make these true)

| ID | What | How |
|---|---|---|
| `windows` | Windows 10 22H2+ or 11, x64 | Already on the machine; abort otherwise |
| `winget` | App Installer | Prompt to install from Store if missing |
| `vcredist` | VC++ 2015–2022 x64 | `winget install Microsoft.VCRedist.2015+.x64` |
| `dotnet8-desktop` | .NET 8 Desktop Runtime | `winget install Microsoft.DotNet.DesktopRuntime.8` |
| `ffmpeg` | FFmpeg **with NVENC** | `winget install Gyan.FFmpeg`, then `ffmpeg -encoders` must list `h264_nvenc` |
| `nvidia-gpu` | NVIDIA GPU with NVENC | `nvidia-smi` must work. Do not pretend AMD/Intel is fine on this host. |
| `nvidia-driver` | Current Game Ready / NVIDIA App driver | **Offer** `NVIDIA.NVIDIAApp`. Never silent-install a driver. |

### Required devices (verify, do not fake)

These are not winget packages. Missing one is a **failed install / not Ready**, same as a failed Rec:

- Microphone (Windows capture device)
- WASAPI loopback (inbox)
- Webcam
- ≥ 50 GB free on the session drive

### Soft (warn, still Ready if Jack confirms)

- Two monitors (game + desk console)
- Private LAN/Wi-Fi for the phone
- Edge (inbox) for the monitor-2 UI

### Optional (ask, never required for Ready)

- OBS Studio — **fallback** capture only, not the in-game default
- Chrome — Edge is enough
- NVIDIA App — driver/GeForce overlay tools, Jack’s choice

### Not on the PC installer

- Android companion APK (phone)
- YouTube OAuth / Discord webhook (studio, after a **committed** recording)

### Must not be required

- Docker Desktop
- CUDA Toolkit
- Python as the capture runtime

## Atomic Ready (install)

Same idea as atomic publish rights:

1. Install/verify packages.
2. Run preflight (GPU, NVENC, mic, cam, disk, FFmpeg encoder list).
3. Write `install-state.json.tmp` → fsync-equivalent flush → rename to `install-state.json`.
4. `status` may be `ready` **only** if every required check passed.
5. Anything else is `not-ready` with a plain-language reason. The app must treat `not-ready` like **NOT RECORDING**: no rec light, no publish.

The installer exits:

| Code | Meaning |
|---|---|
| 0 | Ready — recording is allowed to be armed |
| 2 | Packages may be present, preflight failed — **not Ready** |
| 1 | Install itself failed |

## Jack’s hardware envelope (do not “fix” with more software)

- 8 GB GPU, ~6 GB in the game, ~2 GB leftover
- Capture = host NVENC + isolated files
- Preview = Off / Proxy / absent
- Proxy JPEG over Wi-Fi to the Android app
- No compositor in the game process
- No container beside the game

## Android companion (separate install)

- Android 8+
- Same Wi-Fi as Jack’s PC
- Sideload or Play; pairing QR is printed **only** when host `status=ready`

The phone is not a dependency of the PC installer. If the phone is missing, the PC can still record; it just has no remote.

## Run on Jack’s computer

From an **elevated** PowerShell:

```powershell
cd C:\Users\ianba\Projects\jack-session-console
Set-ExecutionPolicy -Scope Process Bypass
.\install\Install-JackConsole.ps1
```

Verify only (no installs):

```powershell
.\install\Install-JackConsole.ps1 -VerifyOnly
```

Include optional OBS:

```powershell
.\install\Install-JackConsole.ps1 -WithOptional OBS
```
