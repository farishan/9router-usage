#!/usr/bin/env bash
# Install 9router-gtk: copy the indicator into ~/.local/share and autostart it.
#   ./install.sh            install (or reinstall after edits)
#   ./install.sh --uninstall remove the autostart entry and stop the indicator
set -euo pipefail

NAME="9router-usage"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${XDG_DATA_HOME:-$HOME/.local/share}/$NAME"
AUTOSTART_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
PID_FILE="$HOME/.cache/$NAME.pid"

die() {
    printf '%s: %s\n' "${0##*/}" "$*" >&2
    exit 1
}

stop_running() {
    [ -f "$PID_FILE" ] || return 0
    pid="$(cat "$PID_FILE")" || return 0
    if kill "$pid" 2>/dev/null; then
        printf 'stopped running instance (pid %s)\n' "$pid"
    fi
    rm -f "$PID_FILE"
}

do_install() {
    [ -f "$SRC_DIR/$NAME.py" ] || die "no $NAME.py next to this script"

    mkdir -p "$PREFIX" "$AUTOSTART_DIR"
    install -m 0644 "$SRC_DIR/$NAME.py" "$PREFIX/$NAME.py"

    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=9Router Token Usage\n'
        printf "Comment=Show today's non-cached input token usage in the top panel\n"
        printf 'Exec=/usr/bin/python3 %s/%s.py\n' "$PREFIX" "$NAME"
        printf 'Terminal=false\n'
        printf 'Hidden=false\n'
        printf 'NoDisplay=false\n'
        printf 'X-GNOME-Autostart-enabled=true\n'
        printf 'X-GNOME-Autostart-Delay=10\n'
    } >"$AUTOSTART_DIR/$NAME.desktop"

    printf 'installed  %s\n' "$PREFIX/$NAME.py"
    printf 'autostart  %s\n' "$AUTOSTART_DIR/$NAME.desktop"
    printf 'takes effect at next login; to apply now: kill $(cat %s)\n' "$PID_FILE"
}

do_uninstall() {
    stop_running
    rm -f "$AUTOSTART_DIR/$NAME.desktop"
    rm -f "$PREFIX/$NAME.py" "$PREFIX/$NAME.desktop"
    rmdir "$PREFIX" 2>/dev/null || true
    printf 'uninstalled\n'
}

case "${1-}" in
    --uninstall) do_uninstall ;;
    -h | --help)
        sed -n '2,4p' "${BASH_SOURCE[0]}" | cut -c3-
        ;;
    "") do_install ;;
    *) die "unknown option: $1 (try --help)" ;;
esac