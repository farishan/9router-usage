#!/usr/bin/env bash
# verify.sh -- prove the v0.1.0 bar: install, run, uninstall. Repeatably.
#
# Everything runs inside a throwaway HOME, so this cannot disturb the real
# installation and is safe to run while the indicator is up. It deliberately
# does not reuse install.sh's own helpers: a test that calls the code under
# test cannot catch that code being wrong.
#
#   ./verify.sh          run all checks
#   ./verify.sh --help   this text
#
# Exit 0 = every check that could run passed. Exit 1 = something failed.
# SKIP is not PASS. A skipped check means an unverified claim, not a good one.
set -uo pipefail

NAME="9router-usage"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-/usr/bin/python3}"

if [ "${1-}" = "--help" ] || [ "${1-}" = "-h" ]; then
    sed -n '2,14p' "${BASH_SOURCE[0]}" | cut -c3-
    exit 0
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/9router-verify.XXXXXX")"
SB_HOME="$SANDBOX/home"
SB_DATA="$SB_HOME/.local/share"
SB_CONFIG="$SB_HOME/.config"
SB_CACHE="$SB_HOME/.cache"
SB_PREFIX="$SB_DATA/$NAME"
SB_AUTOSTART="$SB_CONFIG/autostart/$NAME.desktop"
SB_PID="$SB_CACHE/$NAME.pid"

BG_PID=""

# Stop any indicator this run started.
#
# Cleanup must kill the indicator, not merely the subshell that launched it.
# `sb ... &` yields the *subshell's* PID, so killing $! leaves python running and
# still registered on the StatusNotifierWatcher bus -- which does not show up as
# a stray process so much as an extra icon in the user's panel, one per run.
# Sweeping by sandbox path is safe because mktemp gives a path unique to this
# run, so it cannot match anything outside this test.
sweep() {
    local pid
    pid="$(cat "$SB_PID" 2>/dev/null || true)"
    case "$pid" in '' | *[!0-9]*) ;; *) kill "$pid" 2>/dev/null ;; esac
    pkill -f "$SANDBOX" 2>/dev/null
    local i
    for ((i = 0; i < 20; i++)); do
        pgrep -f "$SANDBOX" >/dev/null 2>&1 || return 0
        sleep 0.1
    done
    pkill -9 -f "$SANDBOX" 2>/dev/null
    return 0
}

cleanup() {
    sweep
    [ -n "$BG_PID" ] && kill "$BG_PID" 2>/dev/null
    rm -rf "$SANDBOX"
    return 0
}
trap cleanup EXIT

if [ -t 1 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_B=$'\033[1m'; C_N=$'\033[0m'
else
    C_RED=; C_GRN=; C_YEL=; C_B=; C_N=
fi

PASSES=0; FAILS=0; SKIPS=0
ok()  { printf '  %sPASS%s  %s\n' "$C_GRN" "$C_N" "$1"; PASSES=$((PASSES + 1)); }
no()  { printf '  %sFAIL%s  %s\n' "$C_RED" "$C_N" "$1"; FAILS=$((FAILS + 1)); }
sk()  { printf '  %sSKIP%s  %s\n' "$C_YEL" "$C_N" "$1"; SKIPS=$((SKIPS + 1)); }
sec() { printf '\n%s%s%s\n' "$C_B" "$1" "$C_N"; }
note() { printf '        %s\n' "$1"; }

# Run a command as if it were a fresh login under the sandbox HOME.
sb() {
    HOME="$SB_HOME" XDG_DATA_HOME="$SB_DATA" XDG_CONFIG_HOME="$SB_CONFIG" "$@"
}

# Independent re-implementation of "is an instance alive": the flock on the PID
# file is the truth, the PID inside it is only a label.
lock_is_held() {
    exec {fd}<>"$SB_PID" 2>/dev/null || return 1
    if flock -n "$fd"; then
        flock -u "$fd" 2>/dev/null
        exec {fd}>&-
        return 1
    fi
    exec {fd}>&-
    return 0
}

# Is this PID still one of our processes?
#
# Checks the cmdline rather than using `kill -0`, because `kill -0` succeeds on a
# zombie -- a process that has been signalled and is waiting to be reaped is
# already gone for our purposes, but still answers `kill -0`. A zombie's
# /proc/<pid>/cmdline is empty, so this reports it as gone, correctly.
pid_alive_as_ours() {
    [ -r "/proc/$1/cmdline" ] || return 1
    tr '\0' '\n' <"/proc/$1/cmdline" | grep -qx -- ".*$NAME\.py"
}

wait_for() { # wait_for <secs> <command...>
    local deadline=$((SECONDS + $1)); shift
    while [ "$SECONDS" -lt "$deadline" ]; do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    return 1
}

mkdir -p "$SB_CACHE"

BASE_URL="$(sed -n 's/^BASE_URL = "\(.*\)"/\1/p' "$ROOT/$NAME.py")"
[ -n "$BASE_URL" ] || BASE_URL="http://localhost:20128"

printf '%sverify 9router-gtk%s\n' "$C_B" "$C_N"
note "sandbox: $SANDBOX"
note "9Router: $BASE_URL"

# ---------------------------------------------------------------- 1. install
sec "1. install.sh writes the expected files"
out="$(sb "$ROOT/install.sh" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
    no "install.sh exited $rc"
    note "$out"
else
    ok "install.sh exited 0"
fi
[ -f "$SB_PREFIX/$NAME.py" ] \
    && ok "installed script at .local/share/$NAME/$NAME.py" \
    || no "missing installed script at .local/share/$NAME/$NAME.py"
[ -f "$SB_AUTOSTART" ] \
    && ok "autostart entry written" \
    || no "missing autostart entry"
if grep -q "/home/faris" "$SB_PREFIX/$NAME.py" "$SB_AUTOSTART" 2>/dev/null; then
    no "a hardcoded /home/faris path leaked into the installed files"
else
    ok "no hardcoded home path in installed files"
fi
if grep '^Exec=' "$SB_AUTOSTART" 2>/dev/null | grep -qF "$SB_PREFIX/$NAME.py"; then
    ok "Exec= points at the real install prefix"
else
    no "Exec= does not point at the install prefix"
    [ -f "$SB_AUTOSTART" ] && note "$(grep '^Exec=' "$SB_AUTOSTART" 2>/dev/null)"
fi

# ------------------------------------------------------------- 2. .desktop
sec "2. generated .desktop is valid"
if ! command -v desktop-file-validate >/dev/null 2>&1; then
    sk "desktop-file-validate is not installed"
elif out="$(sb desktop-file-validate "$SB_AUTOSTART" 2>&1)" && [ -z "$out" ]; then
    ok "desktop-file-validate clean"
else
    no "desktop-file-validate: ${out:-exited non-zero}"
fi

# ------------------------------------------- 3. stale PID file must not kill
sec "3. a stale PID file never kills an unrelated process"
sleep 300 &
SACRIFICIAL=$!
mkdir -p "$SB_CACHE"
printf '%s\n' "$SACRIFICIAL" >"$SB_PID"
sb "$ROOT/install.sh" >/dev/null 2>&1
if kill -0 "$SACRIFICIAL" 2>/dev/null; then
    ok "unrelated pid $SACRIFICIAL survived the stale pid file"
else
    no "install.sh killed unrelated pid $SACRIFICIAL named by a stale pid file"
fi
kill "$SACRIFICIAL" 2>/dev/null
wait "$SACRIFICIAL" 2>/dev/null
rm -f "$SB_PID"

# ------------------------------------ 4. pre-flock instance must still stop
sec "4. an instance predating the flock is still stopped"
# The real upgrade case: an indicator started before the flock existed holds no
# lock whatsoever. Only its argv still identifies it as ours.
"$PYTHON" -c 'import time; time.sleep(300)' "$NAME.py" >/dev/null 2>&1 &
LEGACY=$!
sleep 0.3
printf '%s\n' "$LEGACY" >"$SB_PID"
sb "$ROOT/install.sh" >/dev/null 2>&1
# Poll rather than blocking-wait: if install.sh fails to stop it, a bare
# `wait` would sit here for the full sleep. A test must never hang on failure.
stopped=0
for ((i = 0; i < 25; i++)); do
    if ! pid_alive_as_ours "$LEGACY"; then stopped=1; break; fi
    sleep 0.2
done
kill "$LEGACY" 2>/dev/null
wait "$LEGACY" 2>/dev/null
if [ "$stopped" -eq 1 ]; then
    ok "lockless instance $LEGACY recognised and stopped"
else
    no "install.sh left a lockless pre-flock instance running"
fi
rm -f "$SB_PID"

# --------------------------------------------------------------- 5. --once
sec "5. installed copy answers --once"
if out="$(sb "$PYTHON" "$SB_PREFIX/$NAME.py" --once 2>&1)"; then
    if printf '%s' "$out" | grep -Eq '^[0-9]+$'; then
        ok "--once printed a number ($out)"
    else
        no "--once printed non-numeric output: $out"
    fi
else
    sk "9Router not answering on $BASE_URL -- start it to cover this"
fi

# --------------------------------------------- 6/7. singleton + reinstall
if [ -z "${DISPLAY:-}" ]; then
    sec "6. a second instance is refused"
    sk "no DISPLAY; cannot hold an instance open to test against"
    sec "7. reinstall stops the old instance and starts a new one"
    sk "no DISPLAY; cannot hold an instance open to test against"
else
    sec "6. a second instance is refused"
    sb "$PYTHON" "$SB_PREFIX/$NAME.py" >/dev/null 2>&1 &
    BG_PID=$!

    if wait_for 5 lock_is_held; then
        ok "first instance holds an exclusive lock on the pid file"

        # Identify the instance via the pid file, the way install.sh does.
        # $! is NOT usable for this: `sb` is a shell function, so `sb ... &`
        # yields the *subshell's* PID, not python's. Asserting against it checks
        # the wrong process, and every result below would be vacuously true.
        OLD_PID="$(cat "$SB_PID" 2>/dev/null || true)"
        if pid_alive_as_ours "$OLD_PID"; then
            ok "running instance identified as pid $OLD_PID"
        else
            no "could not identify the running instance (pid file: '${OLD_PID:-empty}')"
        fi

        out="$(sb "$PYTHON" "$SB_PREFIX/$NAME.py" 2>&1)"; rc=$?
        if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'already running'; then
            ok "second instance refused (exit 1, 'already running')"
        else
            no "second instance: exit $rc, output: ${out:-<empty>}"
            note "expected exit 1 and 'already running' on stderr"
        fi

        sec "7. reinstall stops the old instance and starts a new one"
        out="$(sb "$ROOT/install.sh" 2>&1)"
        if pid_alive_as_ours "$OLD_PID"; then
            no "reinstall left the old instance (pid $OLD_PID) running"
            note "$out"
        else
            ok "reinstall stopped the old instance (pid $OLD_PID)"
        fi
        if wait_for 5 lock_is_held; then
            ok "reinstall started a fresh instance holding the lock"
        else
            no "reinstall did not leave anything running"
            note "it should restart when the indicator was already up"
        fi
    else
        no "first instance never took the lock"
        note "needs DISPLAY and an appindicator host; see README Requirements"
        sec "7. reinstall stops the old instance and starts a new one"
        sk "no instance to test against"
    fi

    kill "$BG_PID" 2>/dev/null
    wait "$BG_PID" 2>/dev/null
    BG_PID=""
fi

# ------------------------------------------------------------ 8. uninstall
sec "8. --uninstall leaves nothing behind"
out="$(sb "$ROOT/install.sh" --uninstall 2>&1)"; rc=$?
if [ "$rc" -eq 0 ]; then
    ok "--uninstall exited 0"
else
    no "--uninstall exited $rc"
    note "$out"
fi
leftover=""
[ -e "$SB_PREFIX" ] && leftover="$leftover prefix"
[ -e "$SB_AUTOSTART" ] && leftover="$leftover autostart-entry"
[ -e "$SB_PID" ] && leftover="$leftover pid-file"
if [ -z "$leftover" ]; then
    ok "no leftovers in sandbox"
else
    no "still present:$leftover"
fi

# ------------------------------------------------------ 9. leaves nothing
sec "9. verify.sh leaves no indicator behind"
leaked="$(pgrep -f "$SANDBOX" 2>/dev/null | tr '\n' ' ')"
if [ -z "$leaked" ]; then
    ok "no instance outlived this run"
else
    no "processes still running out of this sandbox: $leaked"
fi
sweep

# ----------------------------------------------------------------- summary
printf '\n'
if [ "$FAILS" -eq 0 ]; then
    printf '%sverify: %d passed, %d skipped, 0 failed%s\n' "$C_GRN" "$PASSES" "$SKIPS" "$C_N"
    exit 0
fi
printf '%sverify: %d passed, %d skipped, %d FAILED%s\n' "$C_RED" "$PASSES" "$SKIPS" "$FAILS" "$C_N"
exit 1