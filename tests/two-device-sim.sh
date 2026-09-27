#!/usr/bin/env bash
# Two simulated devices + a stand-in cloud (local folder) on one machine.
# Both devices must see the SAME home path (as /home/deck does on PC and Deck),
# so each device's home is swapped in and out of $X/home.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
X="${1:-$(mktemp -d)}"; rm -rf "$X"; mkdir -p "$X/cloud"
H="$X/home"
BIN="$HOME/.local/share/save-sync/bin"
pass=0; fail=0
ok()   { echo "  PASS $*"; pass=$((pass+1)); }
bad()  { echo "  FAIL $*"; fail=$((fail+1)); }

mkdev() {  # mkdev A <game-folder>
  local d="$X/dev-$1"; mkdir -p "$d/.local/share/save-sync/bin" "$d/.config/save-sync" "$d/games/$2/saves"
  ln -s "$BIN/ludusavi" "$BIN/rclone" "$d/.local/share/save-sync/bin/"
  if [ "${CLOUD:-local}" = worker ]; then
    # real Worker + R2, reusing this machine's session (tests only; fake game "Sim Game")
    echo "{\"cloud\": {\"mode\": \"worker\", \"url\": \"$WORKER_URL\"}}" > "$d/.config/save-sync/settings.json"
    install -m600 "$HOME/.config/save-sync/session" "$d/.config/save-sync/session"
  else
    echo "{\"cloud\": {\"mode\": \"local\", \"path\": \"$X/cloud\"}}" > "$d/.config/save-sync/settings.json"
  fi
  cat > "$d/.config/save-sync/games.json" <<J
{"app-$1": {"title": "Sim Game", "runner": "sideload", "exec": "$H/games/$2/game.sh", "prefix": "",
  "game_dir": "$H/games/$2", "save_paths": ["$H/games/$2/saves"], "confirmed": true}}
J
}
on() {     # on A <cmd...> : run with device A's home at $H
  local dev="$1"; shift
  mv "$X/dev-$dev" "$H"
  ( export HOME="$H" SAVESYNC_DEVICE="dev-$dev" SAVESYNC_NO_NOTIFY=1; "$@" ) || true
  mv "$H" "$X/dev-$dev"
}
ss()   { "$REPO/bin/savesync" "$@"; }
game() { ss hook before "app-$DEV" "Sim Game" "$H/games/$GAMEDIR/game.sh" sideload ""; \
         [ -n "${WRITE:-}" ] && echo "$WRITE" > "$H/games/$GAMEDIR/saves/slot1.sav"; \
         ss hook after "app-$DEV" "Sim Game" "$H/games/$GAMEDIR/game.sh" sideload ""; }
play() {   # play A <folder> <content>   (content "" = launch without saving)
  # Ludusavi names backups by the second; two simulated sessions in the same
  # second would reuse a file name and rclone would skip the "unchanged" file.
  sleep 1
  DEV=$1 GAMEDIR=$2 WRITE=$3 on "$1" bash -c "$(declare -f ss game); REPO='$REPO' H='$H' DEV='$1' GAMEDIR='$2' WRITE='$3' game"
}
found() {  # found <text> <dir> : any file (incl. inside backup zips) containing text
  local f
  [ -d "$2" ] || return 0
  grep -rl "$1" "$2" 2>/dev/null | head -1 || true
  while IFS= read -r -d '' f; do
    python3 -c 'import sys,zipfile;z=zipfile.ZipFile(sys.argv[1]);sys.exit(0 if any(sys.argv[2].encode() in z.read(n) for n in z.namelist()) else 1)' "$f" "$1" && echo "$f"
  done < <(find "$2" -name '*.zip' -print0)
  return 0
}
slot() { cat "$X/dev-$1/games/$2/saves/slot1.sav" 2>/dev/null || echo "<none>"; }

. "$REPO/cloud.env"
mkdev A G-1.0; mkdev B G-1.0

echo "1. A plays first → pushes"
play A G-1.0 v1
if [ "${CLOUD:-local}" = worker ]; then
  grep -q "Sim Game: pushed to cloud" "$X/dev-A/.local/share/save-sync/logs/savesync.log" && ok "pushed to R2" || bad "no push"
else
  [ -f "$X/cloud/games/Sim Game.head.json" ] && ok "cloud has a head" || bad "no head in cloud"
fi

echo "2. fresh B launches → pulls A's save"
play B G-1.0 ""
[ "$(slot B G-1.0)" = v1 ] && ok "B got v1" || bad "B has $(slot B G-1.0)"

echo "3. B saves v2; A (unchanged since last sync) launches → auto-pull, no prompt"
play B G-1.0 v2
play A G-1.0 ""
[ "$(slot A G-1.0)" = v2 ] && ok "A got v2" || bad "A has $(slot A G-1.0)"

echo "4. A plays OFFLINE (v3a), B plays online (v3b) → A's next launch is a conflict"
SAVESYNC_OFFLINE=1 play A G-1.0 v3a
[ -f "$X/dev-A/.local/share/save-sync/state/Sim Game.pending" ] && ok "A queued a pending push" || bad "no pending marker"
play B G-1.0 v3b
SAVESYNC_CONFLICT_CHOICE=cloud play A G-1.0 ""
[ "$(slot A G-1.0)" = v3b ] && ok "chose cloud → A has v3b" || bad "A has $(slot A G-1.0)"
q=$(found v3a "$X/dev-A/.local/share/save-sync/conflicts")
[ -n "$q" ] && ok "A's v3a kept in conflicts/" || bad "v3a lost"

echo "5. conflict again, this time keep this device's save"
SAVESYNC_OFFLINE=1 play A G-1.0 v4a
play B G-1.0 v4b
SAVESYNC_CONFLICT_CHOICE=local play A G-1.0 ""
play B G-1.0 ""
[ "$(slot B G-1.0)" = v4a ] && ok "chose local on A → B now has v4a" || bad "B has $(slot B G-1.0)"
q=$(found v4b "$X/dev-A/.local/share/save-sync/conflicts")
[ -n "$q" ] && ok "the losing v4b (from B, via cloud) kept in A's conflicts/" || bad "v4b lost"

echo "6. offline play then back online → flush pushes without replaying"
SAVESYNC_OFFLINE=1 play A G-1.0 v5
on A "$REPO/bin/savesync" sync --pending
play B G-1.0 ""
[ "$(slot B G-1.0)" = v5 ] && ok "flush delivered v5 to B" || bad "B has $(slot B G-1.0)"

echo "7. B updates the game to a new folder G-1.1 → cloud save restored into it"
mkdir -p "$X/dev-B/games/G-1.1/saves"
play A G-1.0 v6
play B G-1.1 ""
[ "$(slot B G-1.1)" = v6 ] && ok "v6 restored into G-1.1" || bad "G-1.1 has $(slot B G-1.1)"

echo "8. conflict on a FRESH device, 'decide later' → launches with its own save, nothing pushed, asks again"
mkdev C G-1.0
echo "c-own" > "$X/dev-C/games/G-1.0/saves/slot1.sav"
SAVESYNC_CONFLICT_CHOICE=later play C G-1.0 ""
[ "$(slot C G-1.0)" = c-own ] && ok "C kept its own save" || bad "C has $(slot C G-1.0)"
grep -q conflict "$X/dev-C/.local/share/save-sync/state/Sim Game.pending" 2>/dev/null && ok "conflict remembered" || bad "no pending conflict"
grep -q "ERROR" "$X/dev-C/.local/share/save-sync/logs/savesync.log" && bad "hook errored" || ok "no hook error"
play B G-1.1 ""
[ "$(slot B G-1.1)" = v6 ] && ok "cloud untouched by C (B still v6)" || bad "B has $(slot B G-1.1)"

echo; echo "passed $pass, failed $fail   (sandbox: $X)"
[ "$fail" = 0 ]
