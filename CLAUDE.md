# save-sync — notes for Claude

Steam-Cloud-style saves for non-Steam games on SteamOS. Heroic (flatpak) is the hub: its
global Before/After launch scripts call `savesync hook before|after …` on the host, which
pulls the newest save before a game starts and uploads it on exit (R2 + rclone crypt, keys
released per device by a Cloudflare Worker after a Google sign-in). `docs/PLAN.md` is the
design, `docs/NOTES.md` the findings log, and `README.md` the user-facing docs.

## Rules
- **Privacy: keep user data out of the project.** The repo is public, so code, comments,
  docs, tests and commit messages use placeholders ("a Ren'Py game", `SpiderMan-1.0-pc`,
  `Sim Game`). Never use the user's game titles, library, play times, hostnames, IP
  addresses or other personal details. Device logs contain such data, so review each diff
  and commit message before committing.
- Keep docs in step with behavior: `README.md` for commands, `docs/NOTES.md` for what was
  learned (incidents, measurements, verified mechanisms).
- Commit only when asked, and confirm before pushing: a push to `main` deploys to every
  device (see self-update).

## Layout
- `bin/savesync`: the whole host-side program (Python, stdlib only, `#!/usr/bin/python3`).
- `install.sh`: idempotent installer and repairer; `get.sh` is the curl bootstrap that pins a
  commit. `savesync update` reuses it with `NONINTERACTIVE=1`.
- `worker/`: the Cloudflare Worker (auth + key release). Deployed separately (`worker/deploy.sh`).
- `systemd/`: a 15-minute timer that uploads pending saves and checks for updates.
- `tests/two-device-sim.sh`: two or three simulated devices plus a local-folder "cloud" on one
  machine. Run it after any sync change: `bash tests/two-device-sim.sh <scratch dir>`.
  `tests/detection-test.sh` covers first-play save-folder detection.

## Sync model
- 3-way: `state/<title>.base.json` (the fp both sides agreed on) vs. local fp vs. the cloud
  `games/<title>.head.json`. Only one side changed → pull or push. Both → conflict prompt.
  The losing side is always kept in `conflicts/`.
- A prompt that can't be shown means "later" and is logged as `(unavailable)`. Never guess
  by "newest wins": a device left asleep mid-game has the newest file times.
- The cloud event log lives in `events/<title>/`, one object per push/pull/conflict
  (`savesync history`). Never put anything inside `games/<title>/`: push mirrors it with
  `rclone sync`, which deletes what isn't in the local backup dir.
- `state/<title>.session.json` records when a session started, from which fp, and whether
  it's still open. An open session whose after-hook never ran gets finished by
  `heroic-exited` / the timer.

## Hard-won platform facts (verified; details in docs/NOTES.md)
- `flatpak-spawn --host` processes have no `DISPLAY` and sit outside Steam's process tree.
  It **does** forward SIGTERM from the sandbox, so hooks ignore TERM/HUP/INT (the signal
  hits savesync only, not rclone/ludusavi).
- Game Mode dialogs: borrow `DISPLAY` + `AppId` from Steam's `reaper SteamLaunch AppId=N …
  com.heroicgameslauncher.hgl` process and set `STEAM_GAME=N` on the window, or gamescope
  never shows it. kdialog can't read a gamepad: savesync maps `/dev/input/js*` to keys with
  xdotool. Use arrow keys, **never Shift+Tab (Steam's overlay shortcut)**.
- Steam keeps a game "running" ("Exiting…") until every process it started exits, and
  never signals the top one. Heroic's Steam shortcut therefore launches via
  `~/.local/share/save-sync/steam-wrap.sh %command% …`. That's plain sh, so Heroic starts
  even if savesync is broken or older. `savesync setup-steam` sets it up through Steam's CEF
  port (127.0.0.1:8080, `SteamClient.Apps.SetShortcutLaunchOptions`) and in shortcuts.vdf
  (written only if the file round-trips byte for byte).
- Killing the game from Steam takes Heroic down before it runs its after-script.

## Self-update (affects testing)
- Every game launch checks `main`'s sha (3 s cap), installs anything newer and re-execs the
  hook. The timer checks every 15 min. The installed version is in
  `~/.local/share/save-sync/src/.commit`.
- So a test build copied onto a device survives only until something newer is pushed: the
  next launch replaces it. Push only when a change is ready, or the device silently runs
  `main` again.
- Anything a Steam launch option or Heroic setting points at must keep working with older
  and newer savesync versions.

## Testing on real devices
- The Steam Deck is reachable over SSH on the LAN. Its host key is known by IP, not by
  hostname. Copy a build to `~/.local/bin/savesync` there and ask the user to play.
- Typing on the Deck is awkward, so do Steam-side setup programmatically (Steam's CEF port
  is open when Decky Loader is installed) rather than asking the user to type. Read `~/.local/share/save-sync/logs/savesync.log` and
  Steam's `~/.local/share/Steam/logs/gameprocess_log.txt`.
- In Game Mode, screenshot with
  `DISPLAY=:0 xprop -root -f GAMESCOPECTRL_REQUEST_SCREENSHOT 32c -set GAMESCOPECTRL_REQUEST_SCREENSHOT 1`
  (→ `/tmp/gamescope.png`). Check focus with `xprop -root GAMESCOPE_FOCUSED_WINDOW`.
- Warn the user before putting a test popup on their screen.
