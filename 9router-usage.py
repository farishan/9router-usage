#!/usr/bin/env python3
import fcntl
import json
import os
import signal
import sys
import urllib.request
import webbrowser

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator3
from gi.repository import GLib, Gtk

BASE_URL = "http://localhost:20128"
STATS_URL = f"{BASE_URL}/api/usage/stats?period=today"
DASHBOARD_URL = f"{BASE_URL}/dashboard/usage"
PID_FILE = os.path.expanduser("~/.cache/9router-usage.pid")
POLL_SECONDS = 30
ICON = "network-transmit-receive-symbolic"


def format_tokens(n):
    if n < 1000:
        return str(n)
    if n < 1_000_000:
        return f"{n / 1000:.1f}k"
    return f"{n / 1_000_000:.1f}M"


def fetch_usage():
    with urllib.request.urlopen(STATS_URL, timeout=5) as resp:
        data = json.load(resp)
    prompt = int(data.get("totalPromptTokens") or 0)
    cached = int(data.get("totalCachedTokens") or 0)
    return max(0, prompt - cached), data


_lock_fd = None


def acquire_singleton():
    """Take an exclusive lock on the PID file, held for this process's lifetime.

    The kernel drops an flock when its holder dies, so a crashed or killed
    indicator never leaves a lock behind and never locks the next launch out.
    That is what makes a stale PID file harmless.

    The PID written inside is a *record* -- for humans, and for install.sh --
    and deliberately not a gate. `os.kill(pid, 0)` succeeds for any live PID,
    including one the kernel has recycled to an unrelated process, so trusting
    it as a gate locked people out permanently. Trust the lock instead.
    """
    global _lock_fd
    os.makedirs(os.path.dirname(PID_FILE), exist_ok=True)
    fd = os.open(PID_FILE, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    os.ftruncate(fd, 0)
    os.write(fd, f"{os.getpid()}\n".encode())
    os.fsync(fd)
    # Raw int fd, not a file object: nothing in Python will garbage-collect it
    # and drop the lock behind our back.
    _lock_fd = fd
    return True


def release_singleton():
    """Drop the lock, leaving the file in place as a record.

    Do not unlink it. Unlinking races with a second process that already opened
    the old inode and locked it: it would be holding a lock on a file that no
    longer has a name, while a third process creates a fresh file and locks
    that too. Two instances, two "successful" locks. Keeping one inode forever
    means exactly one lock forever.
    """
    global _lock_fd
    if _lock_fd is None:
        return
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_UN)
    except OSError:
        pass
    os.close(_lock_fd)
    _lock_fd = None


def build_menu():
    menu = Gtk.Menu()

    info_items = []
    for _ in range(4):
        item = Gtk.MenuItem.new_with_label(" ")
        item.set_sensitive(False)
        menu.append(item)
        info_items.append(item)

    menu.append(Gtk.SeparatorMenuItem())

    open_item = Gtk.MenuItem.new_with_mnemonic("_Open Dashboard")
    open_item.connect("activate", lambda *_: webbrowser.open(DASHBOARD_URL))
    menu.append(open_item)

    quit_item = Gtk.MenuItem.new_with_mnemonic("_Quit")
    quit_item.connect("activate", lambda *_: sys.exit(0))
    menu.append(quit_item)

    menu.show_all()
    return menu, info_items


def build_indicator():
    ind = AppIndicator3.Indicator.new(
        "9router-usage", "", AppIndicator3.IndicatorCategory.APPLICATION_STATUS
    )
    ind.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
    ind.set_title("9Router non-cached input tokens today")
    ind.set_icon_full(ICON, "9Router non-cached input tokens")
    ind.set_label("...", "...")
    menu, info_items = build_menu()
    ind.set_menu(menu)
    return ind, info_items


def refresh(ind, info_items):
    try:
        non_cached, data = fetch_usage()
    except Exception as exc:
        ind.set_label("—", "offline")
        ind.set_title("9Router offline: " + type(exc).__name__)
        info_items[0].set_label("9Router unreachable")
        for item in info_items[1:]:
            item.set_label(" ")
        return GLib.SOURCE_CONTINUE

    label = format_tokens(non_cached)
    ind.set_label(label, label)
    ind.set_title(f"Non-cached input today: {non_cached:,}")

    cached = int(data.get("totalCachedTokens") or 0)
    completion = int(data.get("totalCompletionTokens") or 0)
    requests = int(data.get("totalRequests") or 0)

    info_items[0].set_label(f"Non-cached input: {non_cached:,}")
    info_items[1].set_label(f"Cached input: {cached:,}")
    info_items[2].set_label(f"Output: {completion:,}")
    info_items[3].set_label(f"Requests: {requests:,}")
    return GLib.SOURCE_CONTINUE


def main():
    if "--once" in sys.argv:
        non_cached, _ = fetch_usage()
        print(non_cached)
        return 0

    if not acquire_singleton():
        print("already running", file=sys.stderr)
        return 1

    if not Gtk.init_check([])[0]:
        release_singleton()
        print("no display available", file=sys.stderr)
        return 1

    ind, info_items = build_indicator()
    refresh(ind, info_items)
    # Every GLib source callback must end in GLib.SOURCE_CONTINUE; the default
    # None is SOURCE_REMOVE and silently kills the timer after one poll.
    GLib.timeout_add_seconds(POLL_SECONDS, refresh, ind, info_items)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(0))
    try:
        GLib.MainLoop().run()
    finally:
        release_singleton()
    return 0


if __name__ == "__main__":
    sys.exit(main())