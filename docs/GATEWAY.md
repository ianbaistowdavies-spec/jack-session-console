# Interpretation gateway (parked)

**Status: not needed.** Idle time on Ian's GPU is not a reason to couple Jack's recorder to another machine.

Jack's console records, commits, and (later) interprets/edits on **his** PC after the game releases the GPU. No live offload, no wait-on-Ian, no extra network path in v1.

The notes below are a parked design only. Do not install, require, or mention this gateway as part of Jack's setup.

## Split

| Job | Where | Why |
|---|---|---|
| Game / cam / mic / audio capture | **Jack's PC only** | Pixels and samples live there. You cannot record his session on your GPU without streaming the game live, which we will not do. |
| Rec / stop / markers / replay buffer | Jack's PC + his phone | Fail-loud local truth |
| Atomic commit of masters | Jack's disk | Publish rights are earned here |
| Interpretation (chapters, highlights, transcript, scene cuts, titles) | **Ian's GPU** | Needs VRAM Jack does not have while (or after) gaming |
| Heavy export encode (optional) | Ian's GPU, or Jack overnight | 3090-class card; not during a match |
| Publish (YouTube / Discord) | Still gated on Jack's **committed** session | Gateway output is a derivative, not a substitute recording |

If the gateway is down, Jack still has masters. He is **NOT RECORDING** only when **his** capture is not rolling. Your GPU being off is **INTERPRETATION UNAVAILABLE**, never a silent publish of "interpreted" media that was never interpreted.

## What "interpretation" means here

Work that reads a committed session and writes **sidecar artifacts**, not a new pretend-master:

- Automatic boundaries / chapters
- Highlight / clip candidates
- Speech-to-text of the mic track
- Suggested layout (cam over game) as an edit decision list
- Optional titles, silence maps, loudness

Do **not** ship full masters across the network just to detect cuts. Send a **proxy** first (720p or smaller, already allowed by the Off / Proxy / Full rule). Conform those decisions back onto Jack's isolated masters.

## Fail-loud states on Jack's console

| State | Meaning |
|---|---|
| `gateway-offline` | Ian's box not reachable. Recording still allowed. Interpret / fancy export disabled, reason shown. |
| `gateway-queued` | Committed session accepted; job not finished. |
| `gateway-running` | Your GPU is working this session id. |
| `interpreted` | Sidecars written and hashed. Jack may review, then publish. |
| `interpret-failed` | Loud failure + reason. No fake chapters. Publish of **raw committed masters** is still Jack's choice; publish of "interpreted" is forbidden. |

The gateway **cannot** mint publish rights. Only Jack's recorder can, at commit. Your worker must refuse session ids that are not `committed`.

## Network

Prefer in this order:

1. Same LAN / NAS: Jack commits to a shared folder; your worker watches it.
2. Tailscale (or similar overlay): Jack pushes the **proxy + manifest**, not 100 GB of masters, unless he asked for a remote export.
3. No random public cloud, no port-forward into Jack's PC.

Auth: pairing token, same idea as the Android app. LAN or overlay only.

## Docker: Jack no, Ian maybe

Docker still **must not** wrap Jack's capture.

On **your** machine, Docker is optional and actually reasonable: the 3090 is not in a game, WSL2/GPU-PV can run Whisper / CV / FFmpeg workers in isolation. That is an Ian-side choice, not a Jack install requirement. Jack's `Install-JackConsole.ps1` must stay Ready with the gateway offline.

## What Jack's installer must not do

- Must not require your GPU
- Must not require Docker
- Must not block Rec because interpretation is unavailable
- Must not auto-send facecam/mic off the machine without an explicit "send to studio" (or a Jack-approved always-on pair)

Facecam + mic on your GPU is a privacy choice. Default is **opt-in per session**.
