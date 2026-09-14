# Jack’s PC (as of 2026-09-13)

Source: Jack, via Ian. Unverified on the machine until installer preflight.

| Piece | Spec |
|---|---|
| Motherboard | ASUS TUF Gaming B550M-Plus WiFi II |
| CPU | AMD Ryzen 7 5800X (8C/16T, Zen 3) |
| GPU | NVIDIA GeForce RTX 5060 — **8 GB GDDR7**, Blackwell, 1× 9th-gen NVENC (H.264 / HEVC / AV1) |
| RAM | 16 GB |
| Wi-Fi | On-board (B550M-Plus WiFi II) — phone companion is possible on the same LAN |

AM4 / B550: PCIe 4.0 from the CPU. The 5060 is PCIe 5.0 x8 electrically; it will run x8 Gen4 here. Fine for capture. Do not treat that as a problem.

## What this means for the recorder

**GPU / VRAM — still the tight constraint.** Same envelope as the original 8 GB design:

- Game typically wants ~6 GB
- Leftover for capture ≈ **2 GB**
- Capture = host **NVENC**, isolated files, no OBS compositor on the game
- Preview default **off** (or a tiny proxy on monitor 2), never a second full-res GPU composite while playing
- No Docker, no CUDA toolkit, no live AI on this card during a match

The 5060’s NVENC is **better** than the 8 GB class we designed around (9th gen, AV1). Use it. Do not encode with libx264 while the game is running.

**System RAM — the new constraint.** 16 GB total is tighter than VRAM:

- Game + Discord + Chrome/Edge + Windows will already be hungry
- The recorder must stay **small in RAM**: no Chromium shell, no always-on preview decoder, no Python
- Isolated tracks to disk (NVENC + WASAPI), not frames held in RAM
- Do not recommend a browser PWA as the live UI on this box if we can use a thin native panel

**CPU — comfortable.** 5800X can run WASAPI capture, mux, and a desk UI without competing with the GPU encode path.

**Motherboard Wi-Fi** is enough for the Android companion. Not a reason to require Ethernet.

## Still unknown (need Jack or a look at the box)

- Actual RAM kit (1×16 vs 2×8 — if 1×16, he is in single-channel; worth knowing)
- GPU **board partner** (TUF / other) — does not change capture design
- Monitor count and game resolution / Hz
- Capture drive and free space
- Webcam, mic, Discord
- Windows 10 vs 11 (B550 + 5800X is almost certainly 11)

Installer still refuses Ready without: NVIDIA driver + `nvidia-smi`, FFmpeg with NVENC, mic, camera, ≥50 GB free.
