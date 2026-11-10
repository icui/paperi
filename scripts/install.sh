#!/bin/sh
# Builds the release app, installs it to ~/Applications/Paperi.app and
# (re)launches it. A running copy is stopped gracefully first (SIGTERM:
# management stops and windows are restored), so its exit is clean and the
# login agent does not relaunch the old binary. Pass --no-launch to only
# install.
#
# Grant Accessibility once to the installed app. The ad hoc signature pins
# its designated requirement to the bundle identifier, so the grant survives
# reinstalls (verified with a copy whose code hash differs).
set -eu
cd "$(dirname "$0")/.."
launch=1
for arg in "$@"; do
    case "$arg" in
        --no-launch) launch=0 ;;
        *) echo "usage: $0 [--no-launch]" >&2; exit 2 ;;
    esac
done
./scripts/build-app.sh
dest="$HOME/Applications/Paperi.app"
binary="$dest/Contents/MacOS/Paperi"
if pgrep -f "$binary" >/dev/null 2>&1; then
    printf 'Stopping running Paperi.app…\n'
    pkill -TERM -f "$binary" || true
    tries=0
    while pgrep -f "$binary" >/dev/null 2>&1; do
        tries=$((tries + 1))
        if [ "$tries" -gt 50 ]; then
            echo "Paperi.app did not exit within 5 s; stop it from its menu and rerun" >&2
            exit 1
        fi
        sleep 0.1
    done
fi
mkdir -p "$HOME/Applications"
rm -rf "$dest"
cp -R dist/Paperi.app "$dest"
printf 'Installed %s\n' "$dest"
if [ "$launch" -eq 1 ]; then
    open "$dest"
    printf 'Launched %s (grant Accessibility when prompted on first install; "Start at Login" is in its menu bar item ▥).\n' "$dest"
else
    printf 'Next: open "%s" and grant Accessibility when prompted; enable "Start at Login" from its menu bar item (▥).\n' "$dest"
fi
