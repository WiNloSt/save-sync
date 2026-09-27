#!/usr/bin/env bash
# Regression test for first-play detection (2026-09-27: ~/.config and the whole
# game folder were picked as "save folders" and a backup of them started).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT; echo "sandbox $T"
H="$T/home"; G="$H/games/Fake-1.0-pc"
mkdir -p "$H/.config/FakeCo/FakeGame" "$H/.config/SomeBrowser" "$G/saves" "$H/.local/share/big" "$H/.config/save-sync" "$H/.local/share/save-sync/bin"
ln -s "$HOME/.local/share/save-sync/bin/ludusavi" "$H/.local/share/save-sync/bin/"
echo old > "$H/.config/kdeglobals"; echo old > "$H/.config/SomeBrowser/prefs"
cat > "$H/.config/save-sync/games.json" <<J
{"fake": {"title": "Fake", "runner": "sideload", "exec": "$G/game.sh", "prefix": "",
  "game_dir": "$G", "save_paths": [], "confirmed": false}}
J
export HOME="$H" SAVESYNC_NO_NOTIFY=1
"$REPO/bin/savesync" hook before fake Fake "$G/game.sh" sideload ""
sleep 1
# the "play session": noise everywhere + one real save folder
echo new > "$H/.config/kdeglobals"                 # file directly in a watch root
echo new > "$H/.config/SomeBrowser/prefs"          # another app, one level down
echo log > "$G/log.txt"                            # log in the game root
dd if=/dev/zero of="$H/.local/share/big/blob" bs=1M count=320 status=none   # huge folder
echo slot1 > "$H/.config/FakeCo/FakeGame/save1.dat"   # the real save
"$REPO/bin/savesync" hook after fake Fake "$G/game.sh" sideload ""
python3 - "$H" <<'PY'
import json, sys
g = json.load(open(sys.argv[1] + "/.config/save-sync/games.json"))["fake"]
H = sys.argv[1]
sug, saved = g.get("suggested_paths", []), g.get("save_paths", [])
checks = [
  ("real save folder suggested", H + "/.config/FakeCo/FakeGame" in sug),
  ("~/.config itself NOT suggested", H + "/.config" not in sug),
  ("game root NOT suggested", H + "/games/Fake-1.0-pc" not in sug),
  ("huge folder NOT suggested", H + "/.local/share/big" not in sug),
  ("nothing backed up before confirming", saved == []),
]
fail = 0
for name, ok in checks:
    print(("  PASS " if ok else "  FAIL ") + name); fail += not ok
print("  suggested:", [s.replace(H, "~") for s in sug])
sys.exit(fail)
PY
