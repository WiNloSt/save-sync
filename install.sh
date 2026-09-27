#!/usr/bin/env bash
# install.sh — save-sync: Steam-Cloud-style saves for non-Steam games on SteamOS.
#
# Idempotent; run it on every device (this PC, the Deck, future SteamOS PCs)
# and again after a SteamOS update (`savesync doctor` tells you if you need to).
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

heroic_sandbox() {
  step "Heroic sandbox"
  if ! flatpak info "$HEROIC_APP" >/dev/null 2>&1; then
    warn "Heroic isn't installed. Install it: flatpak install flathub $HEROIC_APP  — then re-run."
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

steam_hint() {
  local vdf
  for vdf in "$HOME"/.local/share/Steam/userdata/*/config/shortcuts.vdf; do
    [ -f "$vdf" ] && grep -qa "$HEROIC_APP" "$vdf" && { ok "Heroic is already in Steam (Gaming Mode)"; return; }
  done
  step "One manual step for Gaming Mode"
  log "Steam → Add a Game → Add a Non-Steam Game → tick 'Heroic Games Launcher'."
  log "That's the only Steam shortcut you need; pick games inside Heroic."
}

uninstall() {
  step "Uninstall"
  [ -x "$SAVESYNC" ] && "$SAVESYNC" unhook-heroic || true
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
  heroic_sandbox || true
  heroic_hooks || true
  cloud_setup
  register_games
  steam_hint
  step "Doctor"
  "$SAVESYNC" doctor || true
  step "Done"
  ok "Add games with Heroic's own Add Game button and play them from Heroic."
  ok "save-sync learns each game on its first launch; saves are backed up when you quit."
}

main "$@"
