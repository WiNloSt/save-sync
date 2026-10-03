#!/usr/bin/env bash
# The "save-sync" entry in Heroic's library (offline, fake HOME): added once with
# Heroic closed, never while it runs, left alone after the user removes it, back
# with --menu, gone on uninstall; launching it never registers it as a game.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.var/app/com.heroicgameslauncher.hgl/config/heroic/sideload_apps"
cat > "$T/.var/app/com.heroicgameslauncher.hgl/config/heroic/sideload_apps/library.json" <<'J'
{"games": [{"runner": "sideload", "app_name": "spiderman", "title": "SpiderMan",
  "install": {"executable": "/home/x/games/SpiderMan-1.0-pc/SpiderMan.sh", "platform": "linux"}}]}
J
HOME="$T" SAVESYNC_NO_NOTIFY=1 /usr/bin/python3 - "$REPO/bin/savesync" <<'PY'
import importlib.machinery, importlib.util, json, subprocess, sys
l = importlib.machinery.SourceFileLoader("ss", sys.argv[1])
spec = importlib.util.spec_from_loader("ss", l); ss = importlib.util.module_from_spec(spec); l.exec_module(ss)
fails = 0
def check(ok, msg):
    global fails
    print(("  PASS " if ok else "  FAIL ") + msg); fails += 0 if ok else 1
lib = lambda: json.loads(ss.HEROIC_LIBRARY.read_text())["games"]
menu = lambda: [e for e in lib() if e["app_name"] == ss.MENU_APP]

ss.heroic_running = lambda: True
check(ss.ensure_menu_entry() is None and not menu(), "Heroic running: library untouched")
ss.heroic_running = lambda: False
ss.ensure_menu_entry()
check(len(menu()) == 1 and lib()[0]["app_name"] == "spiderman", "added; the existing game kept")
e = menu()[0]
check(e["install"]["executable"] == str(ss.MENU_SCRIPT) and ss.MENU_SCRIPT.stat().st_mode & 0o111,
      "runs menu.sh (executable)")
sh = ss.MENU_SCRIPT.read_text()
check(sh.startswith("#!/bin/sh") and "flatpak-spawn --host" in sh and sh.rstrip().endswith("menu"),
      "menu.sh: plain sh, runs `savesync menu` on the host")
r = subprocess.run(["sh", "-n", str(ss.MENU_SCRIPT)])
check(r.returncode == 0, "menu.sh parses")
ss.ensure_menu_entry()
check(len(menu()) == 1, "re-running adds nothing")

data = json.loads(ss.HEROIC_LIBRARY.read_text())
data["games"] = [g for g in data["games"] if g["app_name"] != ss.MENU_APP]
ss.HEROIC_LIBRARY.write_text(json.dumps(data))                    # the user removes it in Heroic
ss.ensure_menu_entry()
check(not menu() and ss.menu_entry_state() == "removed", "removed by the user: stays removed")
ss.ensure_menu_entry(force=True)
check(len(menu()) == 1, "--menu adds it back")

ss.cmd_hook(["before", ss.MENU_APP, "save-sync", str(ss.MENU_SCRIPT), "sideload", ""])
ss.cmd_hook(["after", ss.MENU_APP, "save-sync", str(ss.MENU_SCRIPT), "sideload", ""])
check(ss.MENU_APP not in ss.registry(), "launching it doesn't register it as a game")

ss.remove_menu_entry()
check(not menu() and ss.menu_entry_state() == "missing" and not ss.MENU_SCRIPT.exists(),
      "uninstall removes it (and a reinstall would add it again)")
print(f"\n{'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
PY
