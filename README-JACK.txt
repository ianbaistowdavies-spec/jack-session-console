Jack Session Console
====================

Read WHAT-THIS-IS.txt first — what this is, what v0.1 put on the PC,
and how to remove it.

A recorder for your gaming PC. It sits NEXT TO the game, not on top of it.

What it captures (separate files, mix later):
  - game.mp4      the monitor the game is on  (NVIDIA NVENC — not the CPU)
  - cam.mp4       webcam, 720p on the CPU so the GPU stays with the game
  - mic.m4a       your voice
  - desktop.m4a   game / Discord / whatever you are hearing
  - youtube-mix.mp4  optional: one file with cam in the corner, after you Stop

Nothing is drawn on the game. No OBS overlay. Rec/Stop are a small window
on the other monitor, or hotkeys that work while you are in the match.


Install (once)
--------------
1. Unzip this folder somewhere lasting, e.g.  C:\JackSessionConsole
2. Right-click  Install.bat  →  Run as administrator
3. Wait until it says READY (or read the red lines if FFmpeg / GPU / disk
   failed). No webcam is a warning only — you can still record the game.
4. If Windows SmartScreen complains: More info → Run anyway.


Every session
-------------
1. In the game: use  Borderless windowed  (not exclusive fullscreen).
   Exclusive fullscreen often records a black screen.
2. Double-click  Start-JackConsole.bat
3. Put the console window on your second monitor if you have one.
4. Game display = the monitor the game is on.
5. Tick camera / mic / game audio as you want.
6. F9  = start recording     F10 = stop     F8 = drop a timestamp
   (those keys work while the game has focus)
7. After Stop, optionally click  Make YouTube mix.
   Do that after the match if you can — mixing is extra work for the PC.
8. Files land in  Videos\JackSessions\  (or wherever you set).

Raw tracks stay in the folder so you can edit properly later
(CapCut / DaVinci / Premiere). The mix is just a rough YouTube file.


If game audio is silent
-----------------------
Windows hides "Stereo Mix" on a lot of PCs.

Right-click the speaker icon → Sounds → Recording → right-click empty
area → Show Disabled Devices → enable Stereo Mix (or "Wave Out Mix").
Then pick that in the Game / Discord audio list.

If you use Voicemeeter or a capture cable, pick that instead.


If the game stutters
--------------------
- Uncheck camera while you test, or
- Drop in-game settings one notch, or
- Record  the mix AFTER you quit the game, not during.


Do not
------
- Run OBS at the same time unless you know why
- Run Install.bat every session (only when something is missing)
- Need Docker, Python, or another PC for this to record


Problems: screenshot the red text and send it to Ian.
