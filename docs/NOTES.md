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
- Not yet tested on hardware: a real overlay quit in Gaming Mode (does flatpak-spawn pass
  SIGTERM from the sandbox to the host?). That's a phase-0 spike.
