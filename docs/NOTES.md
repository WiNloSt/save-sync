# Notes & findings

## Heroic (Flatpak v2.22.3)
### Global launch hooks (spike 2026-09-27, log in docs/spikes/)
- `config.json → defaultSettings.beforeLaunchScriptPath / afterLaunchScriptPath` are run for
  every game, including sideloaded ones (`src/backend/launcher.ts`).
- Heroic **waits** for the before-script before starting the game and runs the after-script
  when the game exits (in a `.finally`). Env vars: `HEROIC_GAME_APP_NAME`, `_TITLE`, `_EXEC`,
  `_RUNNER`, `_PREFIX`, `_SCRIPT_STAGE`, `_INFO` (JSON). The exit code is ignored.
- Scripts run inside the sandbox. `flatpak-spawn --host` works once the override grants
  `talk-name=org.freedesktop.Flatpak`.
- **Per-game settings snapshot the globals.** Legacy "explicit" GamesConfig files are written
  in full whenever you change any setting of that game, so an empty script path there would
  bypass the hook. A new game's file is `{}` (inherits). `savesync setup-heroic` patches empty
  per-game paths, and `doctor` flags any that bypass the hook.
- Heroic rewrites `config.json` and `library.json` from memory, so edit them only while it's
  closed. `flatpak ps` detects it; `pgrep -f` gave false positives by matching our own shell.

### Sandbox
- Without extra grants a game can't see `~/games`, and writes to `$HOME/...` land in
  `~/.var/app/com.heroicgameslauncher.hgl/...` (`persistent=.`); XDG_CONFIG_HOME is
  `…/config`. Verified by spike.
- With `--filesystem=~/games --filesystem=~/.renpy`: games are visible and Ren'Py's second
  copy lands in the real `~/.renpy`. Other engines' saves stay in Heroic's private HOME. That's
  fine, because detection watches there and every device launches through Heroic.

### Library
- Sideloaded games are `config/heroic/sideload_apps/library.json` = `{"games":[GameInfo]}`.
- The two phase-1 games keep their `savesync-<slug>` app names. Since the migration they point
  straight at the game's `.sh`.

## Ren'Py (8.3.2)
- Saves exist in two places, and they are **not** kept in step:
  - `<game>/game/saves/`: the complete, current copy. In one real game: 42 files, slots up to 5-3,
    autosaves up to 2026-09-25.
  - `~/.renpy/<save_directory>/`: a partial, older copy. Same game: 24 entries, most last
    written on 2026-09-19, and slots 3-1 onwards are missing. Its `sync/` subfolder belongs to
    Ren'Py's own Sync feature.
- Phase 1 first backed up only `~/.renpy`, which missed the newest saves. Fixed 2026-09-27:
  we now back up **both** locations.
- When a game's launcher moves to a new folder (you point Heroic at `SpiderMan-1.1-pc`), the
  before-hook moves every save path inside the old folder along with it (tested 2026-09-27).
- **Open (phase 2):** `game/saves` sits under a version folder (`SpiderMan-1.0-pc`). A restore
  onto a machine with `SpiderMan-1.1-pc` must be redirected into the current folder. That needs
  a Ludusavi `redirects` entry generated at restore time: old folder → `resolve_dir()`.
- `<save_directory>` is compiled in and unrelated to the game's name:
  one real game uses Ren'Py's default `Testgame-<id>`. It's mapped by identical save contents (`scan`),
  or for a never-played game by which `~/.renpy` dir changed during the first run.
- `~/.renpy/tokens/` (security_keys.txt) is its own Ludusavi game, backed up on every exit.
  Ren'Py 8 warns about saves made on another device unless this is shared. Check in the cloud phase.

## Ludusavi 0.31.0
- `--no-manifest-update` is a **global** flag (before the subcommand).
- Our config is generated JSON (valid YAML), manifest disabled, `roots: []`, so only our
  custom games are ever scanned. Omitted keys fall back to Ludusavi's defaults.
- `wrap` isn't used. `savesync run` launches the game itself so it can forward SIGTERM, detect
  the save dir on first play, and later own the cloud sync direction.

## Incident 2026-09-27: detection picked ~/.config and the whole game folder
- The first real Heroic launch on the PC (a Ren'Py game, not yet confirmed) ran first-play detection even
  though the Ren'Py rule already knew its folders. Other apps writing to `~/.config` during play,
  plus `log.txt` in the game root, made `~/.config` and the game's root the "save folders". The
  after-hook then started backing them up (a partial 8.7 GB zip), and Heroic showed the game as
  still running while it waited. It was killed by hand; nothing was uploaded (push only follows a
  successful backup), and the partial zip was deleted.
- Fixes:
  - Detection runs only when no engine rule applies.
  - A watch root, HOME or the game root is never suggested.
  - Anything over 300 MB or 3000 files is rejected.
  - Results are only **suggestions**, never backed up until the user adds them; `--confirm`
    refuses when there's more than one.
  - The noise filter now checks the home-relative path, so `/tmp/` in an absolute path no longer
    hides everything.
- Regression test: `tests/detection-test.sh`.

## Size (2026-09-27): a fresh device downloaded 192 MB for 13 MB of saves
- Each backup held `game/saves` (13 MB) plus `~/.renpy/<dir>` (16 MB, the partial, older copy),
  about 28 MB with screenshots that don't compress, and the pull fetched all 9 versions.
- Now: Ren'Py backs up `game/saves` only (`~/.renpy` only when game/saves has no saves);
  retention is 5 versions; a pull downloads only the cloud's newest backup and appends it to the
  device's own history.

## Cloud (R2 + crypt + Worker), 2026-09-27
- **Downloads from R2 stalled** at random points (a 12.9 MB file stuck at 9-10 MiB for minutes,
  on both PC and Deck, while uploads and 42 MB/s speed tests were fine). This is rclone's HTTP/2
  to R2: `--s3-disable-http2` (plus `--multi-thread-streams 0`) gives 6/6 downloads at about 0.4 s.
  It was not the Wi-Fi, not the Deck, and not the encryption layer (raw objects stalled too).
- `rclone cat` of a missing object on R2 exits 0 with empty output (the local stand-in errored).
  An empty head is read as "nothing in the cloud yet".
- The rclone remote is defined only by env vars (`RCLONE_CONFIG_R2_*`, `RCLONE_CONFIG_SS_*`),
  built from the Worker's `/keys` answer per sync. No rclone.conf, no keys on disk.
- `tests/two-device-sim.sh`: 10/10 against the stand-in AND (`CLOUD=worker`) against the real
  Worker + R2 + crypt.
- Pasted secrets can carry stray whitespace (a leading space in the Google Client ID broke
  sourcing .env). Values are trimmed on save.

## Incident 2026-10-01: conflict popup never showed in Game Mode
- A Deck left asleep mid-game for over a day while the PC played and pushed.
  On exit, the conflict was detected correctly, but `kdialog` aborted (`qt.qpa.xcb: could not
  connect to display`, rc −6). `{0,1}.get(rc, "later")` turned that into "Decide later", so it
  played the Deck's stale save and asked "again" every launch, with no popup and no sign of it.
  Nothing was overwritten in the cloud.
- Why: hooks reach the host through `flatpak-spawn --host`, which has no `DISPLAY`. Even with
  `DISPLAY=:1` (Heroic's Xwayland; `STEAM_MULTIPLE_XWAYLANDS=1`), gamescope only shows windows
  it ties to the focused app. It finds that app by walking a window's process tree up to
  `reaper SteamLaunch AppId=N`, and our host process isn't in that tree.
- Fix (verified with a screenshot via `GAMESCOPECTRL_REQUEST_SCREENSHOT`): take `DISPLAY` and
  `AppId` from that reaper process and set `STEAM_GAME=N` on the dialog's windows
  (`xdotool search --pid`, `xprop -set`). gamescope then focuses the dialog over Heroic.
- Controller: kdialog only takes keyboard and mouse, and Game Mode has no keyboard (only the
  trackpad worked, with Steam held). Steam keeps feeding its virtual Xbox pad (`/dev/input/js0`,
  user-readable) to the focused window, so while the dialog is up savesync turns it into keys
  with `xdotool`: d-pad / stick → Left / Right, A → Space, B → Escape ("Decide later"). Not
  Tab: **Shift+Tab is Steam's overlay shortcut** and opened the sidebar. Verified on the Deck.
- A dialog that can't be shown is now logged as `(unavailable)`, never as a user choice. It is
  also never "newest wins": the asleep Deck had the newest file times (an autosave at quit,
  plus Ren'Py rewriting `persistent`) while holding the older progress.
- Every push / pull / conflict now goes to `events/<title>/` in the cloud (`savesync
  history`). Heads carry `parent` and `session_start`.

## Steam waits for save-sync when Heroic closes (Game Mode, 2026-10-01)
- flatpak-spawn **does** forward SIGTERM from the sandbox to the host process. Closing Heroic
  killed an upload half-way, so hooks now ignore TERM/HUP/INT. The signal reaches savesync
  only, not the rclone/ludusavi it runs.
- Hooks run on the host via flatpak-spawn, outside Steam's process tree. So "Exit game"
  returned at once while the upload was still running, with nothing on screen. Sleeping the
  Deck right then could cut the upload off.
- Steam counts a game as running until every process it started has exited. It never signals
  the top one: a test wrapper that outlived Heroic by 30 s kept "Exiting…" up for all 30 s,
  with no kill. With `%command%`, a non-Steam shortcut's launch option wraps the whole chain
  (`steam-launch-wrapper → reaper → flatpak run`).
- So Heroic's shortcuts launch through `~/.local/share/save-sync/steam-wrap.sh %command% …`.
  When Heroic exits, the wrapper runs `savesync heroic-exited`, which waits for the hook lock
  (hooks hold `state/hook.lock` shared). It also finishes any session whose after-hook never
  ran: killing the game from Steam takes Heroic down before it runs its after-script.
- The wrapper is plain sh, not savesync. A launch-time update once replaced a test build with
  a version that lacked the wrapper command, which would have stopped Heroic from launching.
- `savesync setup-steam` sets the launch option, live through Steam's CEF debug port
  (`SteamClient.Apps.SetShortcutLaunchOptions`, open when Decky is installed) and in
  shortcuts.vdf (written only if it round-trips byte for byte). The installer runs it, and a
  Game Mode launch without the wrapper re-applies it for next time.
- Measured on the Deck: quit, then Exit game → held 3 s until the upload finished. Killed
  mid-game → the open session was backed up and uploaded, and Steam waited ~6 s for it.
- Adding the shortcut live: `SteamClient.Apps.AddShortcut(name, exe, startDir, opts)` returns
  the app id, but names the shortcut after the exe and ignores startDir and opts. Set them with
  `SetShortcutName` / `SetShortcutStartDir` / `SetShortcutLaunchOptions`. Pass the exe
  unquoted, because Steam adds the quotes. Steam writes shortcuts.vdf within a second, so
  re-runs see it and never add a duplicate.
- With Steam closed, the installer writes the entry into shortcuts.vdf itself (appid =
  `crc32(exe + name) | 0x80000000`). With Steam open and no CEF port, it changes nothing and
  asks the user to quit Steam and re-run.
- Heroic writes `config.json` (where the hooks go) about 3 s after its first start, without
  any clicks. The installer starts it once on a fresh device, then closes it.

## Popups and the save-sync entry in Heroic (2026-10-03, desktop)
- Heroic has no plugin API; its only extension point is the launch hooks. What isn't tied to a
  launch lives in a sideloaded library entry (`app_name` `savesync-menu`) whose executable is
  `~/Games/Heroic/save-sync/menu/menu.sh`. The hooks return at once for that app name. Its
  folder is its own (`menu/`), never the hook's: Heroic can delete a sideloaded app's folder on
  uninstall.
- Heroic launches a native sideloaded app with the sandbox's cwd, `/app/bin`. `flatpak-spawn
  --host` then fails with "Portal call failed: Failed to change to directory /app/bin" before
  anything runs; `menu.sh` does `cd "$HOME"` first. (The hooks never hit this.) The
  `EROFS ... chmod '/app/bin/gamemoderun'` error after every sideloaded launch is harmless:
  real games log it too.
- Heroic holds `sideload_apps/library.json` in memory and writes it back, so the entry is added
  only while Heroic is closed (`setup-heroic`, or the 15-minute timer). Once added,
  `settings.json` remembers it, so an entry the user removed is never re-added.
- A process started from a hook with `start_new_session=True` outlives `flatpak-spawn --host`
  (checked from inside Heroic's sandbox). The sign-in popup relies on it: the browser sign-in
  finishes in the background while the game starts.
- kdialog (25.04): a button's icon comes from its role, not its label: Yes `dialog-ok` (✓),
  No `process-stop` (red), Cancel `dialog-cancel`, Continue `arrow-right`. The left button is
  always Yes. Escape and the window's close button pick No when there's no Cancel (KMessageBox:
  anything but Yes is the secondary action). There's no option for icons or colours, and Qt's
  `-stylesheet` is rejected as an unknown option. So a two-button kdialog can't have the
  destructive action on the right *and* a safe Escape.
- Destructive confirmations therefore use a small QML popup (`confirm.qml`, run with `qml6`,
  Breeze via `QT_QUICK_CONTROLS_STYLE=org.kde.desktop`): safe button left and focused, red
  destructive button right, Escape / close / B = safe, exit code 10 = do it.
  `tests/confirm-popup-test.sh` drives it off-screen. **`/usr/bin/qml` is Qt 5's runtime**
  (qt5-declarative); Qt 6's is `qml6`. Without it, kdialog is used with the destructive action
  first and the two icons swapped through an icon-theme overlay in `XDG_DATA_DIRS` that only
  that popup sees (`kiconfinder6` confirms the lookup).
- Going back to an older backup made before the game moved to a new version folder would
  restore into the old folder. `restore --preview --api --backup` shows where each file would
  go; save-sync adds a restore redirect to the current folder, and fails loudly if the live
  saves didn't change.
- Not yet seen in Game Mode: the folder popup, the menu (its up/down key mapping), the QML popup.

## Tested
- 2026-09-27, through real Heroic, never-seen fake game: the before-hook registered it, the
  first play session detected `…/config/FakeCo/FakeGame` (the `.log` was filtered), and the
  after-hook backed it up. It also wrongly picked the game's own folder, because the test
  wrote a file there. That's what the confirmation step is for.
- 2026-09-27, snapshot walk of the watch roots: about 9k files in 0.17 s.

### Earlier (phase-1 launcher design, fake game in a throwaway HOME)
- First play: save dir mapped automatically, config regenerated, backup made.
- SIGTERM to savesync (what Steam's "Exit game" sends): passed to the game's process group, the
  game saved on TERM, backup ran afterwards, exit code 143 passed through.
- Answered 2026-10-01: flatpak-spawn does pass SIGTERM from the sandbox to the host (see the
  Steam section above).
