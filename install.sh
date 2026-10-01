#!/usr/bin/env bash
# install.sh — save-sync: Steam-Cloud-style saves for non-Steam games on SteamOS.
#
# One command sets up a device: Heroic (installed if missing), its launch hooks,
# save-sync itself, cloud sign-in, and Heroic's Steam shortcut for Game Mode.
# Idempotent: every step checks first, so re-running repairs and never
# duplicates. Run it again after a SteamOS update (`savesync doctor` tells you).
# Everything lives under $HOME, so atomic OS updates don't touch it.
#
# Usage:
#   ./install.sh              install / repair everything
#   ./install.sh --uninstall  remove save-sync (keeps your backups)
#
# Phase 1 = local versioned backups on game exit. Cloud sync comes later
# (docs/PLAN.md); this installer already fetches rclone for it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$REPO_ROOT/lib/common.sh"
# shellcheck source=versions.env
source "$REPO_ROOT/versions.env"

APP_HOME="$HOME/.local/share/save-sync"
CACHE="$HOME/.cache/save-sync"
HEROIC_APP=com.heroicgameslauncher.hgl
HEROIC_CONFIG="$HOME/.var/app/$HEROIC_APP/config/heroic/config.json"
SAVESYNC="$HOME/.local/bin/savesync"

install_binaries() {
  step "Ludusavi $LUDUSAVI_VERSION + rclone $RCLONE_VERSION"
  mkdir -p "$APP_HOME/bin"
  if [ "$("$APP_HOME/bin/ludusavi" --version 2>/dev/null)" != "ludusavi $LUDUSAVI_VERSION" ]; then
    fetch_verified "$LUDUSAVI_URL" "$LUDUSAVI_SHA256" "$CACHE/ludusavi-$LUDUSAVI_VERSION.tar.gz"
    tar -xzf "$CACHE/ludusavi-$LUDUSAVI_VERSION.tar.gz" -C "$APP_HOME/bin" ludusavi
    chmod 755 "$APP_HOME/bin/ludusavi"
  fi
  ok "$("$APP_HOME/bin/ludusavi" --version)"
  if ! "$APP_HOME/bin/rclone" version 2>/dev/null | head -1 | grep -q "v$RCLONE_VERSION\$"; then
    fetch_verified "$RCLONE_URL" "$RCLONE_SHA256" "$CACHE/rclone-$RCLONE_VERSION.zip"
    local tmp; tmp="$(mktemp -d)"
    /usr/bin/python3 -c 'import sys,zipfile;zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
      "$CACHE/rclone-$RCLONE_VERSION.zip" "$tmp"
    install -m755 "$tmp"/rclone-*/rclone "$APP_HOME/bin/rclone"
    rm -rf "$tmp"
  fi
  ok "$("$APP_HOME/bin/rclone" version | head -1)"
}

install_cli() {
  step "savesync CLI"
  mkdir -p "$HOME/.local/bin"
  install -m755 "$REPO_ROOT/bin/savesync" "$SAVESYNC"
  ok "installed $SAVESYNC"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) warn "~/.local/bin is not on PATH in this shell";; esac
}

heroic_install() {
  step "Heroic Games Launcher"
  if flatpak info "$HEROIC_APP" >/dev/null 2>&1; then ok "installed"; return 0; fi
  if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    warn "Heroic isn't installed; re-run the install line to add it"; return 1
  fi
  log "Installing Heroic from Flathub (for this user)…"
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user -y --noninteractive flathub "$HEROIC_APP" && ok "installed"
}

heroic_first_run() {
  # Heroic writes config.json (where its launch hooks go) on first start: ~3 s.
  [ -f "$HEROIC_CONFIG" ] && return 0
  flatpak info "$HEROIC_APP" >/dev/null 2>&1 || return 1
  [ "${NONINTERACTIVE:-0}" = "1" ] && return 1
  flatpak ps --columns=application 2>/dev/null | grep -qx "$HEROIC_APP" && return 1
  log "Starting Heroic once so it creates its settings (it closes again by itself)…"
  flatpak run "$HEROIC_APP" >/dev/null 2>&1 &
  local i
  for i in $(seq 60); do [ -f "$HEROIC_CONFIG" ] && break; sleep 1; done
  sleep 3                                   # let it finish writing
  flatpak kill "$HEROIC_APP" 2>/dev/null || true
  for i in $(seq 10); do flatpak ps --columns=application | grep -qx "$HEROIC_APP" || break; sleep 1; done
  [ -f "$HEROIC_CONFIG" ] && ok "Heroic settings created" || { warn "Heroic didn't create its settings"; return 1; }
}

heroic_sandbox() {
  step "Heroic sandbox"
  if ! flatpak info "$HEROIC_APP" >/dev/null 2>&1; then
    warn "Heroic isn't installed: skipped"
    return 1
  fi
  # - talk-name: the hook script runs savesync on the host (flatpak-spawn --host)
  # - ~/games: games live there and write into their own folders (Ren'Py game/saves)
  # - ~/.renpy: otherwise Ren'Py's second save copy lands in Heroic's private HOME
  flatpak override --user --talk-name=org.freedesktop.Flatpak \
    --filesystem=~/games --filesystem=~/.renpy "$HEROIC_APP"
  ok "Heroic: host access for hooks, ~/games and ~/.renpy visible"
}

heroic_hooks() {
  step "Heroic global launch hooks"
  if flatpak ps --columns=application 2>/dev/null | grep -qx "$HEROIC_APP"; then
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then
      warn "Heroic is running; quit it and run: savesync setup-heroic"; return 1
    fi
    read -r -p "Heroic is running and must be closed to change its settings. Close it now? [y/N] " a || true
    case "$a" in y|Y) flatpak kill "$HEROIC_APP"; sleep 2 ;; *) warn "Skipped. Later: savesync setup-heroic"; return 1 ;; esac
  fi
  "$SAVESYNC" setup-heroic
}

register_games() {
  step "Games"
  "$SAVESYNC" gen-config
  "$SAVESYNC" list
  if [ -s "$HOME/.config/save-sync/games.json" ] && [ "$(cat "$HOME/.config/save-sync/games.json")" != "{}" ]; then
    step "Baseline backup"
    "$SAVESYNC" backup >/dev/null && ok "backed up every known game"
  fi
}

cloud_setup() {
  step "Cloud sync"
  # shellcheck source=cloud.env
  . "$REPO_ROOT/cloud.env"
  if [ -z "${WORKER_URL:-}" ]; then
    warn "No Worker configured in cloud.env yet: local backups only."
    return 0
  fi
  mkdir -p "$HOME/.config/save-sync"
  /usr/bin/python3 - "$WORKER_URL" <<'PY'
import json, sys, pathlib
p = pathlib.Path.home() / ".config/save-sync/settings.json"
s = json.loads(p.read_text()) if p.exists() else {}
s["cloud"] = {"mode": "worker", "url": sys.argv[1]}
p.write_text(json.dumps(s, indent=2) + "\n")
PY
  ok "cloud: $WORKER_URL"
  mkdir -p "$HOME/.config/systemd/user"
  install -m644 "$REPO_ROOT"/systemd/save-sync-flush.* "$HOME/.config/systemd/user/"
  systemctl --user daemon-reload
  systemctl --user enable --now save-sync-flush.timer >/dev/null 2>&1 && ok "retry timer on (every 15 min)"
  # Ask the Worker, not just "does the file exist": a revoked/expired sign-in
  # must re-open the browser, a valid one must never.
  case "$("$SAVESYNC" status 2>/dev/null)" in
    "signed in"*) ok "this device is signed in" ;;
    "can't reach"*) warn "Worker unreachable; keeping the existing sign-in" ;;
    *)
      if [ "${NONINTERACTIVE:-0}" != "1" ]; then
        log "Sign this device in with Google (once). A browser tab will open."
        "$SAVESYNC" login || warn "Not signed in. Later: savesync login"
      else
        warn "Not signed in. Run: savesync login"
      fi ;;
  esac
}

steam_shortcut() {
  # Game Mode: Heroic as a Steam shortcut, launched through save-sync's wrapper so
  # closing it shows "Exiting…" until saves are uploaded.
  [ -d "$HOME/.local/share/Steam/userdata" ] || return 0      # no Steam on this machine
  step "Steam (Game Mode)"
  if "$SAVESYNC" setup-steam 2>/dev/null | grep -q "No Heroic shortcut"; then
    local want
    want="$(/usr/bin/python3 -c 'import json,pathlib;p=pathlib.Path.home()/".config/save-sync/settings.json";print(json.loads(p.read_text()).get("steam_shortcut","ask") if p.exists() else "ask")')"
    if [ "$want" = "no" ]; then
      ok "Heroic isn't in Steam (you chose that; add it: savesync setup-steam --add)"; return 0
    fi
    if [ "${NONINTERACTIVE:-0}" = "1" ]; then return 0; fi
    read -r -p "Add Heroic to Steam so you can play from Game Mode? [Y/n] " a || true
    case "${a:-y}" in
      n|N)
        /usr/bin/python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / ".config/save-sync/settings.json"
s = json.loads(p.read_text()) if p.exists() else {}
s["steam_shortcut"] = "no"
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(s, indent=2) + "\n")
PY
        ok "skipped (later: savesync setup-steam --add)"; return 0 ;;
    esac
    "$SAVESYNC" setup-steam --add && ok "Heroic is in Steam; closing it waits for save-sync" || warn "see above"
  else
    ok "Heroic is in Steam; closing it waits for save-sync"
  fi
}

uninstall() {
  step "Uninstall"
  [ -x "$SAVESYNC" ] && "$SAVESYNC" unhook-heroic || true
  [ -x "$SAVESYNC" ] && "$SAVESYNC" setup-steam --remove || true
  systemctl --user disable --now save-sync-flush.timer >/dev/null 2>&1 || true
  rm -f "$HOME"/.config/systemd/user/save-sync-flush.* "$HOME/.config/save-sync/session"
  rm -f "$SAVESYNC"
  rm -rf "$APP_HOME/bin" "$HOME/.config/save-sync/ludusavi"
  ok "removed. Kept: backups in $APP_HOME/backups, registry in ~/.config/save-sync/games.json"
  log "The Heroic flatpak override (talk-name, ~/games, ~/.renpy) is left in place;"
  log "remove it with: flatpak override --user --reset $HEROIC_APP  (resets ALL your Heroic overrides)"
}

main() {
  case "${1:-}" in
    --uninstall) uninstall; return ;;
    --help|-h) sed -n '2,14p' "$0"; return ;;
    "") ;;
    *) die "unknown option: $1" ;;
  esac
  install_binaries
  install_cli
  heroic_install || true
  heroic_first_run || true
  heroic_sandbox || true
  heroic_hooks || true
  cloud_setup
  register_games
  steam_shortcut
  step "Doctor"
  "$SAVESYNC" doctor || true
  step "Done"
  ok "Add games with Heroic's own Add Game button and play them from Heroic."
  ok "save-sync learns each game on its first launch; saves are backed up when you quit."
}

main "$@"
