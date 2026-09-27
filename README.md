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

Then:
1. A browser tab opens: sign in with Google (once per device). Google warns the app isn't
   verified, because it's a private app in testing mode. Click **Continue**.
2. For Gaming Mode, add Heroic to Steam once: Steam → **Add a Game → Add a Non-Steam Game** →
   tick **Heroic Games Launcher**.
3. Add games with Heroic's own **Add Game** button and play them from Heroic. Each game's save
   folder is found on its first launch.

It installs the latest `main` branch into your home folder, so SteamOS updates don't touch it.
Re-running the same line updates or repairs it.

## Everyday commands

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
savesync devices
```
Signed-in devices; `savesync devices --revoke <id>` signs one out.

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
| Not yet tested | a real Heroic launch, the conflict dialog on screen, Gaming Mode, a second physical device |
| GUI: "where does it save?" dialog, Save Sync window + Heroic tile | next |

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
        first play: add folders the game wrote to; ludusavi backup (zip, 10 versions); push

before: base / local / cloud fingerprints → nothing | pull | push | conflict prompt
cloud:  R2 bucket, rclone crypt (names + contents encrypted); keys fetched per sync from
        the Worker with this device's session, held in memory only
```
- **Adding a game:** use Heroic's own **Add Game** button, then launch it once. save-sync
  registers it on that first launch. Games can live anywhere Heroic can see; `~/games` is granted.
- **Save folders:** found automatically (Ren'Py rule; otherwise by watching what the first
  play session writes). They start as *not confirmed*.
  - `savesync list`: what it picked
  - `savesync paths <game> --set <folder>…`: repick (confirms)
  - `savesync paths <game> --add <folder>`: add one
  - `savesync paths <game> --confirm`: accept what it found
  - `savesync paths <game> --detect`: forget it and watch the next play again
- **Gaming Mode:** add Heroic to Steam once (Add a Non-Steam Game), then launch games inside Heroic.
- **Only Heroic sideloaded games for now.** GOG/Epic launches are logged and skipped.
- **Backups:** `~/.local/share/save-sync/backups/<game>/`. Restore with
  `~/.local/share/save-sync/bin/ludusavi --config ~/.config/save-sync/ludusavi restore "<Title>"`.

## Files
| Path | Purpose |
|---|---|
| `~/.local/bin/savesync` | CLI (copied from `bin/savesync`) |
| `~/.local/share/save-sync/bin/` | pinned ludusavi + rclone (`versions.env`, sha256-checked) |
| `~/.config/save-sync/games.json` | registry, keyed by Heroic app name: save folders, confirmed flag |
| `~/.config/save-sync/ludusavi/config.yaml` | generated. Don't edit: rewritten from the registry |
| `~/Games/Heroic/save-sync/hook.sh` | the global Before/After script Heroic runs |
| `~/.local/share/save-sync/logs/savesync.log` | log of every hook run |
