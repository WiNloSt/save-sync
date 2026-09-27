#!/bin/sh
# save-sync bootstrap:
#   curl -fsSL https://raw.githubusercontent.com/WiNloSt/save-sync/main/get.sh | sh
# Downloads save-sync into ~/.local/share/save-sync/src and runs its installer.
# `savesync update` reuses this with SAVESYNC_REF=<commit> NONINTERACTIVE=1.
set -eu
REPO="WiNloSt/save-sync"
REF="${SAVESYNC_REF:-}"
if [ -z "$REF" ]; then
  # pin the exact commit so the installed version is known (for self-update)
  REF="$(curl -fsSL "https://api.github.com/repos/$REPO/commits/main" 2>/dev/null \
         | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -1)" || true
  [ -n "$REF" ] || REF=main
fi
DEST="$HOME/.local/share/save-sync/src"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[*] downloading save-sync ($(printf %.7s "$REF"))"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/$REF" | tar -xz -C "$TMP"
rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"
mv "$TMP"/save-sync-* "$DEST"
printf '%s\n' "$REF" > "$DEST/.commit"
# stdin is the curl pipe; give the installer the terminal for its questions
# (-r /dev/tty is true even with no controlling terminal, so actually try to open it)
if (exec </dev/tty) 2>/dev/null; then exec "$DEST/install.sh" "$@" < /dev/tty; fi
exec "$DEST/install.sh" "$@"
