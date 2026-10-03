# save-sync

Steam-Cloud-style saves for non-Steam games on SteamOS. Every game you launch from
Heroic pulls the newest save before it starts and uploads yours when you quit, across all
your SteamOS machines. Conflicts get a Steam-style "keep cloud or keep this device?" prompt,
and the save you don't pick is kept.

## Install on a device

In **Desktop Mode**, open **Konsole** and run:

```sh
curl -fsSL https://raw.githubusercontent.com/WiNloSt/save-sync/main/get.sh | sh
```

That one line sets up everything, and running it again only repairs what's missing:
- **Heroic**: installed from Flathub if missing, its launch hooks wired to save-sync.
- **Sign-in**: a browser tab opens; sign in with Google (once per device). Google warns the
  app isn't verified, because it's a private app in testing mode. Click **Continue**.
- **Game Mode**: it offers to add Heroic to Steam, set up so that closing it waits for your
  saves to upload. If Steam is open and can't be changed live, it tells you to quit Steam
  and re-run.

Then add games with Heroic's own **Add Game** button and play them from Heroic. Each game's
save folder is found on its first launch:
- **Ren'Py games** need nothing more: their save folder is known, and syncing starts at once.
- **Other games**: after the first play, a popup shows each folder the game wrote to.
  Choose **Sync this folder**, **Not this one** or **Ask next time**. Nothing is synced until
  you pick one, and an unanswered popup asks again at the next launch.

### The save-sync entry in Heroic
The installer adds **save-sync** to Heroic's library. Launch it like a game (Desktop or Game
Mode, controller works) for everything that isn't tied to playing:
- each game's status: synced, waiting to upload, conflict, or no save folder yet
- **Save folders…**: stop syncing one, decide on suggestions, add one, or watch the next play
- **Go back to an older save…**: restore one of this device's backups; it syncs to your other
  devices, and the saves it replaces are kept in `~/.local/share/save-sync/conflicts/`
- **History**: which device saved, uploaded or downloaded when
- **Sign in** when this device isn't (Desktop Mode: it opens the browser)

Popups that would lose something (stop syncing, forget folders, go back) put the safe choice
on the left, focused; the destructive one is red on the right. Escape, closing the window and
the controller's B are always the safe choice.

If you remove the entry from Heroic, it stays removed; `savesync setup-heroic --menu` (with
Heroic closed) adds it back.

It installs the latest `main` branch into your home folder, so SteamOS updates don't touch it.
It **updates itself**: at every game launch (before the game starts, so a fix applies right
away) and every 15 minutes it checks GitHub and installs any new version (never mid-game).
Turn that off with `"auto_update": false` in `~/.config/save-sync/settings.json`.
Re-running the same line also updates or repairs it.

## Everyday commands
Everything below is optional: the popups and the save-sync entry in Heroic cover day-to-day
use. The commands are for checking and fixing things from a terminal.

```sh
savesync doctor
```
Is everything wired up?

```sh
savesync list
```
Games and their save folders.

```sh
savesync paths "<game>" --set /path/to/saves
```
Repick a game's save folder (also `--add`, `--confirm`, `--detect`).

```sh
savesync status
```
Is this device signed in? (Re-running the installer never asks you to sign in again while the
sign-in is valid.)

```sh
savesync update
```
Update now instead of waiting for the next launch or timer check.

```sh
savesync devices
```
Signed-in devices; `savesync devices --revoke <id>` signs one out.

```sh
savesync restore "<game>" [<backup>]
```
List this device's backups of a game, or go back to one (same as the menu's
**Go back to an older save…**).

```sh
savesync history "<game>"
```
The cloud's log for a game: which device pushed, pulled or hit a conflict, when, and from which
save.

```sh
savesync resolve "<game>" cloud|local
```
Settle a save conflict without the popup. The popup also works in Game Mode: d-pad to pick,
A to confirm, B = Decide later.

In Game Mode, closing Heroic (even killing the game from Steam) shows **Exiting…** until your
saves are uploaded. The installer sets this up on Heroic's Steam shortcut; `savesync setup-steam`
redoes it, `savesync setup-steam --remove` undoes it.

```sh
~/.local/share/save-sync/src/install.sh --uninstall
```
Remove save-sync (quit Heroic first, so its launch hooks can be removed). Your backups are kept.

## Status
| Part | State |
|---|---|
| Heroic global hook, save-folder detection, versioned local backups | done |
| Sync: pull on launch, push on exit, 3-way conflict check, offline queue + retry timer | done |
| Cloudflare Worker (Google sign-in → session → keys), R2 + rclone crypt | done, deployed |
| Tested | 2 simulated devices, 10/10 scenarios, on the real Worker + R2 |
| Popups: "where does it save?", sign-in, errors; save-sync menu entry in Heroic | done (desktop); Game Mode not yet tested |

Design: [docs/PLAN.md](docs/PLAN.md) · findings: [docs/NOTES.md](docs/NOTES.md) · tests: `tests/two-device-sim.sh`

## Running your own
Everything account-specific lives in Cloudflare/Google, not in this repo. See
`worker/deploy.sh` and the credential table in docs/PLAN.md. Point `cloud.env` at your Worker.

## How it works
```
Heroic launches any game
  ├─ Before-launch script (global) ─► flatpak-spawn --host savesync hook before …
  │     new game? register it; Ren'Py rule or snapshot files to watch the first play
  ├─ the game runs (Heroic's sandbox; ~/games and ~/.renpy are granted)
  └─ After-launch script (global)  ─► flatpak-spawn --host savesync hook after …
        first play: ask about the folders the game wrote to; ludusavi backup (zip); push

before: base / local / cloud fingerprints → nothing | pull | push | conflict prompt
cloud:  R2 bucket, rclone crypt (names + contents encrypted); keys fetched per sync from
        the Worker with this device's session, held in memory only
```
- **Adding a game:** use Heroic's own **Add Game** button, then launch it once. save-sync
  registers it on that first launch. Games can live anywhere Heroic can see; `~/games` is granted.
- **Save folders:** found automatically (Ren'Py rule; otherwise by watching what the first
  play session writes, then asking in a popup). Change them in the save-sync entry in Heroic,
  or from a terminal:
  - `savesync list`: what it picked, and suggestions still waiting for an answer
  - `savesync paths <game> --set <folder>…`: repick (confirms)
  - `savesync paths <game> --add <folder>`: add one
  - `savesync paths <game> --confirm`: accept what it found
  - `savesync paths <game> --detect`: forget it (and any "Not this one") and watch the next play again
- **Gaming Mode:** add Heroic to Steam once (Add a Non-Steam Game), then launch games inside Heroic.
- **Only Heroic sideloaded games for now.** GOG/Epic launches are logged and skipped.
- **Backups:** `~/.local/share/save-sync/backups/<game>/`. Go back to one from the save-sync
  entry in Heroic, or with `savesync restore "<game>" <backup>`; it follows a game that moved
  to a new version folder, and the replaced saves are kept in `conflicts/`.

## Files
| Path | Purpose |
|---|---|
| `~/.local/bin/savesync` | CLI (copied from `bin/savesync`) |
| `~/.local/share/save-sync/bin/` | pinned ludusavi + rclone (`versions.env`, sha256-checked) |
| `~/.config/save-sync/games.json` | registry, keyed by Heroic app name: save folders, confirmed flag |
| `~/.config/save-sync/ludusavi/config.yaml` | generated. Don't edit: rewritten from the registry |
| `~/Games/Heroic/save-sync/hook.sh` | the global Before/After script Heroic runs |
| `~/Games/Heroic/save-sync/menu/` | the save-sync library entry: `menu.sh` (runs `savesync menu`) and its cover |
| `~/.local/share/save-sync/confirm.qml` | the popup for destructive confirmations (written by savesync) |
| `~/.local/share/save-sync/logs/savesync.log` | log of every hook run |
