# Jack Session Console

Session recorder for Jack’s gaming PC: isolated game / camera / audio tracks, no overlay on the match, mix after Stop.

**Docker is not used.** Capture stays on the Windows host.

## For Jack

Read **`README-JACK.txt`**. Short version:

1. Right-click `Install.bat` → Run as administrator (once).
2. Double-click `Start-JackConsole.bat` before a session.
3. **F9** rec, **F10** stop, **F8** marker. Game stays focused.
4. After Stop, optional **Make YouTube mix**. Raw tracks stay in `Videos\JackSessions\`.

Use **borderless windowed** in the game, not exclusive fullscreen.

## Installer (advanced)

```powershell
.\install\Install-JackConsole.ps1
.\install\Install-JackConsole.ps1 -VerifyOnly
```

Exit codes: `0` ready, `2` not ready, `1` install error. Atomic Ready flag: `state/install-state.json`.
