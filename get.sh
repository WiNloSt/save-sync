#!/bin/sh
# save-sync bootstrap:
#   curl -fsSL https://raw.githubusercontent.com/WiNloSt/save-sync/main/get.sh | sh
# Downloads the latest save-sync into ~/.local/share/save-sync/src and runs its installer.
set -eu
REPO="WiNloSt/save-sync"
BRANCH="${SAVESYNC_BRANCH:-main}"
DEST="$HOME/.local/share/save-sync/src"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[*] downloading save-sync ($BRANCH)"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP"
rm -rf "$DEST"; mkdir -p "$(dirname "$DEST")"
mv "$TMP"/save-sync-* "$DEST"
# stdin is the curl pipe; give the installer the terminal for its questions
# (-r /dev/tty is true even with no controlling terminal, so actually try to open it)
if (exec </dev/tty) 2>/dev/null; then exec "$DEST/install.sh" "$@" < /dev/tty; fi
exec "$DEST/install.sh" "$@"
