# save-sync

Steam-Cloud-style saves for non-Steam games on SteamOS. Every game you launch from
Heroic pulls the newest save before it starts and uploads yours when you quit, across all
your SteamOS machines. Conflicts get a Steam-style "keep cloud or keep this device?" prompt,
and the save you don't pick is kept.

## Install (each device, Desktop Mode)
```
curl -fsSL https://raw.githubusercontent.com/WiNloSt/save-sync/main/get.sh | sh
```
It installs into your home folder (safe across SteamOS updates), hooks into Heroic, and
opens a browser tab once to sign this device in with Google. Then add Heroic to Steam once
(Add a Non-Steam Game) for Gaming Mode, and add games with Heroic's **Add Game** button.

```
savesync doctor            # is everything wired up?
savesync list              # games and their save folders
savesync devices           # signed-in devices (--revoke <id>)
./install.sh --uninstall   # remove (keeps backups)
```

## Status
| Part | State |
|---|---|
| Heroic global hook, save-folder detection, versioned local backups | done |
| Sync: pull on launch, push on exit, 3-way conflict check, offline queue + retry timer | done (tested with 2 simulated devices) |
| Cloudflare Worker: Google sign-in → session → keys; R2 + rclone crypt | built, deploy pending |
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
