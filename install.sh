#!/usr/bin/env bash
# Install 9router-gtk: copy the indicator into ~/.local/share and autostart it.
#   ./install.sh            install (or reinstall after edits; restarts if running)
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

require_flock() {
    command -v flock >/dev/null 2>&1 \
        || die "flock(1) not found (util-linux); it is how liveness is determined safely, and without it a stale PID file can point at an unrelated process that this script would then kill"
}

# Is the exclusive lock on the PID file held by someone?
#
# 9router-usage.py holds an flock on the PID file for its whole lifetime and the
# kernel drops it the moment the process dies. So a held lock means "running",
# unambiguously, with no PID heuristics involved.
lock_is_held() {
    exec {lock_fd}<>"$PID_FILE" 2>/dev/null || return 1
    if flock -n "$lock_fd"; then
        flock -u "$lock_fd" 2>/dev/null || true
        exec {lock_fd}>&-
        return 1
    fi
    exec {lock_fd}>&-
    return 0
}

# Does this bare PID belong to one of our own processes?
#
# Positive evidence only. The old code did `kill <pid-from-file>` on faith, which
# means "kill whatever the kernel recycled that number to". This asks instead.
pid_is_ours() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' '\n' <"/proc/$1/cmdline" | grep -qx -- ".*$NAME\.py"
}

stop_running() {
    [ -e "$PID_FILE" ] || return 0
    require_flock

    local pid held=0 ours=0
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    lock_is_held && held=1
    case "$pid" in '' | *[!0-9]*) ;; *) pid_is_ours "$pid" && ours=1 ;; esac

    # Either signal on its own is sufficient, and neither can fire by accident:
    #   held -> running under the current design
    #   ours -> genuinely this program, which is what catches an instance that
    #           predates the flock (it holds no lock at all) and an orphan left
    #           by a crash. Both are real, and both should be stopped.
    if [ "$held" -eq 0 ] && [ "$ours" -eq 0 ]; then
        printf 'no running instance (stale pid file ignored)\n'
        return 0
    fi

    case "$pid" in
        '' | *[!0-9]*)
            printf 'an instance is running but the pid file is unreadable; not guessing\n' >&2
            return 0
            ;;
    esac

    kill "$pid" 2>/dev/null || true

    # Wait until neither signal still fires, so callers know the old code is
    # genuinely gone rather than mid-exit.
    local i still
    for ((i = 0; i < 25; i++)); do
        still=0
        lock_is_held && still=1
        pid_is_ours "$pid" && still=1
        if [ "$still" -eq 0 ]; then
            printf 'stopped running instance (pid %s)\n' "$pid"
            return 0
        fi
        sleep 0.2
    done
    printf 'warning: pid %s did not exit; continuing anyway\n' "$pid" >&2
}

start_running() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$PYTHON" "$PREFIX/$NAME.py" >/dev/null 2>&1 &
    else
        nohup "$PYTHON" "$PREFIX/$NAME.py" >/dev/null 2>&1 &
        disown || true
    fi
}

do_install() {
    require_flock
    [ -f "$SRC_DIR/$NAME.py" ] || die "no $NAME.py next to this script"
    PYTHON="${PYTHON:-/usr/bin/python3}"

    local was_running=0
    if [ -e "$PID_FILE" ] && { lock_is_held || {
        case "$(cat "$PID_FILE" 2>/dev/null || true)" in
            '' | *[!0-9]*) false ;;
            *) pid_is_ours "$(cat "$PID_FILE" 2>/dev/null)" ;;
        esac
    }; }; then
        was_running=1
    fi
    stop_running

    mkdir -p "$PREFIX" "$AUTOSTART_DIR"
    install -m 0644 "$SRC_DIR/$NAME.py" "$PREFIX/$NAME.py"

    {
        printf '[Desktop Entry]\n'
        printf 'Type=Application\n'
        printf 'Name=9Router Token Usage\n'
        printf "Comment=Show today's non-cached input token usage in the top panel\n"
        printf 'Exec=%s %s/%s.py\n' "$PYTHON" "$PREFIX" "$NAME"
        printf 'Terminal=false\n'
        printf 'Hidden=false\n'
        printf 'NoDisplay=false\n'
        printf 'X-GNOME-Autostart-enabled=true\n'
        printf 'X-GNOME-Autostart-Delay=10\n'
    } >"$AUTOSTART_DIR/$NAME.desktop"

    printf 'installed  %s\n' "$PREFIX/$NAME.py"
    printf 'autostart  %s\n' "$AUTOSTART_DIR/$NAME.desktop"

    # Restart only if it was already up, so `./install.sh` after an edit leaves
    # the new code actually running instead of silently dead until next login.
    if [ "$was_running" -eq 1 ]; then
        start_running
        printf 'restarted  (running the new code)\n'
    else
        printf 'not running; starts at next login\n'
    fi
}

do_uninstall() {
    require_flock
    stop_running
    rm -f "$AUTOSTART_DIR/$NAME.desktop"
    rm -f "$PREFIX/$NAME.py" "$PREFIX/$NAME.desktop"
    rmdir "$PREFIX" 2>/dev/null || true
    rm -f "$PID_FILE"
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