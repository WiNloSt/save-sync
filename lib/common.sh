#!/usr/bin/env bash
# lib/common.sh — shared helpers for the save-sync installer. Sourced, not run.

# Keep Homebrew's python3/tar out of the way; savesync targets /usr/bin/python3.
_sanitize_path() {
  local out= d IFS=:
  for d in $PATH; do
    case "$d" in /home/linuxbrew/*|*/.linuxbrew/*|*/Cellar/*) continue ;; esac
    case ":$out:" in *":$d:"*) continue ;; esac
    out="${out:+$out:}$d"
  done
  PATH="$out"; export PATH
}
_sanitize_path

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_BOLD=$'\e[1m'
else
  C_RESET=; C_BLUE=; C_GREEN=; C_YELLOW=; C_RED=; C_BOLD=
fi
log()  { printf '%s[*]%s %s\n'  "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s[✓]%s %s\n'  "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n'  "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n'  "$C_RED"    "$C_RESET" "$*" >&2; }
step() { printf '\n%s==== %s ====%s\n' "$C_BOLD" "$*" "$C_RESET"; }
die()  { err "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# fetch_verified <url> <sha256> <dest> : download once into the cache, verify.
fetch_verified() {
  local url="$1" sum="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  if [ -f "$dest" ] && echo "$sum  $dest" | sha256sum -c --status; then
    ok "cached: $(basename "$dest")"; return 0
  fi
  log "downloading $(basename "$dest")"
  curl -fL --retry 3 -o "$dest.part" "$url" || die "download failed: $url"
  echo "$sum  $dest.part" | sha256sum -c --status || { rm -f "$dest.part"; die "checksum mismatch: $url"; }
  mv "$dest.part" "$dest"
  ok "verified: $(basename "$dest")"
}
