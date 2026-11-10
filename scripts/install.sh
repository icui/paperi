#!/bin/sh
# Builds the release app and installs it to ~/Applications/Paperi.app.
# Grant Accessibility once to the installed app; rebuilding the repository
# does not change it. Re-running this script replaces the binary, which with
# the default ad hoc signature requires granting Accessibility again (set
# PAPERI_SIGN_IDENTITY to a code-signing identity to keep the grant).
set -eu
cd "$(dirname "$0")/.."
./scripts/build-app.sh
dest="$HOME/Applications/Paperi.app"
if pgrep -f "$dest/Contents/MacOS/Paperi" >/dev/null 2>&1; then
    echo "Paperi.app is running; stop it first (menu › Stop & Restore Windows, or: paperi msg stop)" >&2
    exit 1
fi
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R dist/Paperi.app "$dest"
printf 'Installed %s\n' "$dest"
printf 'Next: open "%s" and grant Accessibility when prompted; enable "Start at Login" from its menu bar item (▥).\n' "$dest"
