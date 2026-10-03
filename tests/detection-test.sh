#!/usr/bin/env bash
# Regression test for first-play detection (2026-09-27: ~/.config and the whole
# game folder were picked as "save folders" and a backup of them started), and
# for the save-folder popup that follows it (SAVESYNC_FOLDER_CHOICE answers it).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT; echo "sandbox $T"
H="$T/home"; G="$H/games/Fake-1.0-pc"; G2="$H/games/Other-1.0-pc"
mkdir -p "$H/.config/FakeCo/FakeGame" "$H/.config/SomeBrowser" "$G/saves" "$G2" "$H/.local/share/big" "$H/.config/save-sync" "$H/.local/share/save-sync/bin"
ln -s "$HOME/.local/share/save-sync/bin/ludusavi" "$H/.local/share/save-sync/bin/"
echo old > "$H/.config/kdeglobals"; echo old > "$H/.config/SomeBrowser/prefs"
cat > "$H/.config/save-sync/games.json" <<J
{"fake": {"title": "Fake", "runner": "sideload", "exec": "$G/game.sh", "prefix": "",
  "game_dir": "$G", "save_paths": [], "confirmed": false},
 "other": {"title": "Other", "runner": "sideload", "exec": "$G2/game.sh", "prefix": "",
  "game_dir": "$G2", "save_paths": [], "confirmed": false}}
J
export HOME="$H" SAVESYNC_NO_NOTIFY=1
ss() { "$REPO/bin/savesync" "$@"; }
SAVESYNC_FOLDER_CHOICE=later ss hook before fake Fake "$G/game.sh" sideload ""
sleep 1
# the "play session": noise everywhere + one real save folder
echo new > "$H/.config/kdeglobals"                 # file directly in a watch root
echo new > "$H/.config/SomeBrowser/prefs"          # another app, one level down
echo log > "$G/log.txt"                            # log in the game root
dd if=/dev/zero of="$H/.local/share/big/blob" bs=1M count=320 status=none   # huge folder
echo slot1 > "$H/.config/FakeCo/FakeGame/save1.dat"   # the real save
SAVESYNC_FOLDER_CHOICE=later ss hook after fake Fake "$G/game.sh" sideload ""
cp "$H/.config/save-sync/games.json" "$T/after-first-play.json"

# 2nd launch: the popup is asked again before the game starts; the user says yes
SAVESYNC_FOLDER_CHOICE=yes ss hook before fake Fake "$G/game.sh" sideload ""
SAVESYNC_FOLDER_CHOICE=yes ss hook after fake Fake "$G/game.sh" sideload ""

# another game: the user says "Not this one", so the same folder isn't suggested again
mkdir -p "$H/.config/OtherCo/Settings"
for _ in 1 2; do
  SAVESYNC_FOLDER_CHOICE=no ss hook before other Other "$G2/game.sh" sideload ""
  sleep 1; date +%N > "$H/.config/OtherCo/Settings/options.ini"
  SAVESYNC_FOLDER_CHOICE=no ss hook after other Other "$G2/game.sh" sideload ""
done
grep -c "save folders other: .*OtherCo/Settings -> no" "$H/.local/share/save-sync/logs/savesync.log" > "$T/asked-other"

python3 - "$H" "$T" <<'PY'
import json, sys, os
H, T = sys.argv[1], sys.argv[2]
first = json.load(open(T + "/after-first-play.json"))["fake"]
reg = json.load(open(H + "/.config/save-sync/games.json"))
g, o = reg["fake"], reg["other"]
sug, saved = first.get("suggested_paths", []), first.get("save_paths", [])
real = H + "/.config/FakeCo/FakeGame"
checks = [
  ("real save folder suggested", real in sug),
  ("~/.config itself NOT suggested", H + "/.config" not in sug),
  ("game root NOT suggested", H + "/games/Fake-1.0-pc" not in sug),
  ("huge folder NOT suggested", H + "/.local/share/big" not in sug),
  ("'Ask next time': nothing backed up yet", saved == [] and not first.get("confirmed")),
  ("'Sync this folder' at the next launch: it's a save folder now", real in g.get("save_paths", [])),
  ("... confirmed, and no suggestions left over", g.get("confirmed") is True and real not in g.get("suggested_paths", [])),
  ("... and backed up when the game exited", os.path.isdir(H + "/.local/share/save-sync/backups/Fake")),
  ("'Not this one': remembered", H + "/.config/OtherCo/Settings" in o.get("rejected_paths", [])),
  ("... and not asked about again", open(T + "/asked-other").read().strip() == "1"),
  ("... nothing synced for that game", o.get("save_paths") == []),
]
fail = 0
for name, ok in checks:
    print(("  PASS " if ok else "  FAIL ") + name); fail += not ok
print("  suggested:", [s.replace(H, "~") for s in sug])
sys.exit(fail)
PY
