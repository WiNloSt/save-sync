#!/usr/bin/env bash
# setup-steam without a running Steam: adds Heroic's shortcut to shortcuts.vdf
# already wrapped, never twice, keeps other shortcuts intact, and --remove undoes
# the wrapping. (The live path through Steam's CEF port is tested on a device.)
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; [ -n "${KEEP:-}" ] || trap 'rm -rf "$T"' EXIT
mkdir -p "$T/.local/share/Steam/userdata/12345/config"
HOME="$T" /usr/bin/python3 - "$REPO/bin/savesync" <<'PY'
import importlib.machinery, importlib.util, sys
l = importlib.machinery.SourceFileLoader("ss", sys.argv[1])
spec = importlib.util.spec_from_loader("ss", l); ss = importlib.util.module_from_spec(spec); l.exec_module(ss)
ss.steam_running = lambda: False                  # Steam closed
def no_cef(_expr, timeout=5): raise OSError("no CEF port")
ss.steam_js = no_cef
ss.log = lambda m: None
vdf = ss.STEAM_USERDATA / "12345/config/shortcuts.vdf"
fails = 0
def check(ok, msg):
    global fails
    print(("  PASS " if ok else "  FAIL ") + msg); fails += 0 if ok else 1

# 1. an account with no shortcuts.vdf yet
ss.cmd_setup_steam(["--add"], quiet=True)
found = ss.heroic_shortcuts()
check(len(found) == 1, "Heroic shortcut added")
sc = found[0][2]
check(sc["LaunchOptions"].startswith(ss.STEAM_WRAP) and "heroic-run" in sc["LaunchOptions"], "already wrapped")
check(sc["appid"] & 0x80000000 and sc["appname"] == "Heroic Games Launcher", "Steam-style appid and name")
check(ss.STEAM_WRAPPER.exists(), "wrapper script written")

# 2. idempotent
before = vdf.read_bytes()
ss.cmd_setup_steam(["--add"], quiet=True); ss.cmd_setup_steam([], quiet=True)
check(vdf.read_bytes() == before, "re-running changes nothing")

# 3. --remove unwraps, setup re-wraps
ss.cmd_setup_steam(["--remove"], quiet=True)
check(ss.heroic_shortcuts()[0][2]["LaunchOptions"] == ss.HEROIC_SHORTCUT_OPTS, "--remove restores the plain options")
ss.cmd_setup_steam([], quiet=True)
check(vdf.read_bytes() == before, "setup-steam wraps it again")

# 4. other shortcuts survive, and the new one gets the next index
other = {"shortcuts": {"0": {"appid": 2222222222, "appname": "Some Tool", "Exe": '"/usr/bin/true"',
                             "StartDir": "/usr/bin/", "LaunchOptions": "", "IsHidden": 0, "tags": {"0": "x"}}}}
vdf.write_bytes(ss.vdf_dump(other))
ss.cmd_setup_steam(["--add"], quiet=True)
d = ss.vdf_load(vdf.read_bytes())[0]["shortcuts"]
check(d["0"] == other["shortcuts"]["0"] and d["1"]["appname"] == "Heroic Games Launcher", "existing shortcut kept, Heroic added as #1")

# 5. Steam running without a CEF port: no file write, a clear message
ss.steam_running = lambda: True
vdf.write_bytes(ss.vdf_dump(other))
ok, msg = ss.add_heroic_shortcut()
check(not ok and "Steam is running" in msg and ss.vdf_load(vdf.read_bytes())[0] == other, "Steam running: untouched, explains what to do")
print(f"\n{'all passed' if not fails else f'{fails} failed'}")
sys.exit(1 if fails else 0)
PY
