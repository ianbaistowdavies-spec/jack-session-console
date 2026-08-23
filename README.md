# Jack Session Console

Session recorder for Jack’s gaming PC: isolated game / camera / audio tracks, Android companion over Wi-Fi, publish only after a committed recording.

**Docker is not used.** Capture stays on the Windows host. See `docs/DEPENDENCIES.md`.

## Install on Jack’s computer

Elevated PowerShell:

```powershell
cd C:\Users\ianba\Projects\jack-session-console
Set-ExecutionPolicy -Scope Process Bypass
.\install\Install-JackConsole.ps1
```

Verify without installing:

```powershell
.\install\Install-JackConsole.ps1 -VerifyOnly
```

The installer writes `state/install-state.json` **atomically**. `status` is `ready` only if every required dependency is present and verified. Otherwise it is `not-ready`: the box must not claim it is recording and must not publish.

Exit codes: `0` ready, `2` not ready, `1` install error.
