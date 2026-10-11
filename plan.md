# 9router-gtk — investigation notes

**Status: installed and working.** See `README.md` for usage. This file is the
investigation record, the safety rules, and the corrections made to my own
earlier diagnosis.

---

## Corrections to the original diagnosis

Three things I got wrong earlier. All are recorded here because the wrong version
would mislead anyone reading this later.

### 3. The indicator was never actually polling — `refresh()` returned `None`

**Found 2026-10-11 16:45.** The panel label froze at `567.4k` while `curl` read
698,860. The bug was in the GLib source callback convention:

```python
GLib.timeout_add_seconds(POLL_SECONDS, refresh, ind, info_items)
```

`refresh()` had no `return` statement, so it returned `None`. In PyGObject
`None` is `False` is `GLib.SOURCE_REMOVE`, so **the timer deleted itself after its
first fire**. The label therefore reflected the single poll at startup plus one
poll 30s later, and never again.

The reflex to "return `False` to keep going" is wrong for GLib, and it is the
opposite of what the name suggests:

| Return value | Meaning |
| --- | --- |
| `GLib.SOURCE_CONTINUE` = `True` | fire again |
| `GLib.SOURCE_REMOVE` = `False` | delete the source |

Measured on this machine (PyGObject 3.42.1 / GLib 3.42.1), 1s interval, 6s window:

```
None  -> fired 1 time     False -> fired 1 time     True -> fired 6 times
```

Every path through `refresh()` now ends in `return GLib.SOURCE_CONTINUE`.

**How to see this class of bug without a debugger.** The label is the only symptom,
so read it off D-Bus and watch it move:

```sh
gdbus introspect --session --dest org.kde.StatusNotifierWatcher \
  --object-path /StatusNotifierWatcher   # find ":1.N/org/ayatana/NotificationItem/9router_usage"
gdbus introspect --session --dest :1.N --object-path /org/ayatana/NotificationItem/9router_usage \
  | grep -E "Title|XAyatanaLabel"
```

And to confirm polls are actually leaving the process, sample `/proc/net/tcp`
(9Router is port `20128` = `0x4EA0`) for 60s; each poll is a new ephemeral
source port. Zero new ports means the timer is dead, whatever the label says.
`strace -p` does not work here — `kernel.yama.ptrace_scope=1`.

### 1. systray2 was NOT the cause of the flicker

The original plan claimed 9Router's systray2 tray was creating a rogue
override-redirect X window and repainting it in the top-right.

**This was disproven by observation.** systray2 (`tray_linux_release`, pid 7449)
ran continuously for 30+ minutes with `ubuntu-appindicators` disabled and produced
no flicker. The Mutter `needs an allocation` warnings numbered 9 at shell startup
(15:40) and again at 15:48, then **stopped for the remaining 28 minutes of the
session** while systray2 kept running. systray2 running is therefore not
*sufficient* to cause the flicker.

The inference was plausible but untested at the time it was made.

### 2. Enabling `ubuntu-appindicators` was not a fix

It was originally listed as the required fix for an active bug. It is not. It is
simply **a prerequisite for rendering anything in a tray at all** — without a
`StatusNotifierWatcher` on the session bus, no tray item can be shown by anything.
It was a red herring that happened to also be a genuine requirement.

### The actual root cause

Unchanged, and it was never in doubt: the `hi@faris` segfault documented in that
extension's own README —

> `gnome-shell` segfaulted (signal 11) 24s after `gnome-extensions enable hi@faris`.
> Safe mode then disabled all user extensions. Crash cause never confirmed.

`hi@faris` is currently `INITIALIZED` (dormant), held there by
`disable-user-extensions=true`. The cause was never root-caused.

### No reboot was required

The machine was stable (gnome-shell uptime 36 min, no new Mutter warnings, systray2
running cleanly). Rebooting would have been pure downside risk. The only cleanup
needed was trashing two leftover `/tmp/systray_*` PNGs.

---

## Why a shell extension was rejected

`hi@faris` set a **static** label once in `enable()` — zero ongoing work, zero I/O,
nothing that can fail afterwards. That is why "hi" worked.

Dynamic content is a different risk class. It requires work *inside* the shell
process every 30 seconds. GNOME Shell is single-threaded and draws every frame;
blocking I/O or a bad timer callback freezes the entire desktop, and the only exit
is killing the shell. That matches the segfault profile.

**The resolution was to keep the rendering and move the work out of process.** The
shipped `ubuntu-appindicators` extension does the drawing; a separate Python process
does the polling. The shell performs no I/O on our behalf.

---

## Safety rules — enforced in the implementation

1. **Out-of-process.** Own PID; cannot segfault `gnome-shell`.
2. **Never create a `Gtk.Window`.** The only X connection is the one `Gtk.init` opens
   for icon-theme and `Gtk.Menu` support — required because `set_menu()` accepts only
   `Gtk.Menu`, and clicks must go through a D-Bus menu. (An earlier X-free variant was
   written and abandoned: `Gio.DBusMenuModel` is abstract and `Indicator` exposes no
   `activate` signal, so click handling is impossible without GTK.)
3. **Never `GtkStatusIcon`** — the API implicated in the original flicker.
4. **Never set global GTK state** — no theme name, icon theme, CSS provider,
   `GDK_SCALE`. These force shell-wide repaints.
5. **No shell extension enabled or modified.** `hi@faris` untouched.
6. **No restart loop.** The autostart entry has no wrapper.
7. **Singleton PID lock** at `~/.cache/9router-usage.pid` — refuses to start twice.
8. **`try/except` around every poll** — verified: an unreachable server yields `—`,
   not a crash.
9. **Quit via exact PID**, never a broad `pkill`.
10. **Autostart delay of 10s** so the shell settles first.

---

## Two distinct "disabled" settings — do not conflate

| Setting | Value | Origin |
| --- | --- | --- |
| `disable-user-extensions` | `true` | **Automatic** — GNOME safe mode after the segfault |
| `disabled-extensions` | `['ubuntu-appindicators@ubuntu.com']` | **Manual** |

The schema default for `disabled-extensions` is `[]`
(`/usr/share/glib-2.0/schemas/org.gnome.shell.gschema.xml:24-25`), so that value was
set deliberately.

It was almost certainly **not** set from a GUI: GNOME Settings has no extensions page,
Tweaks 42 has no Extensions tab, and the stock Extensions app only enumerates *user*
extensions from `~/.local/share`, while `ubuntu-appindicators` is a *session* extension
in `/usr/share/gnome-shell/extensions`.

---

## Data source

```sh
curl http://localhost:20128/api/usage/stats?period=today
```

HTTP 200 with no auth on this instance (`requireLogin` off).

```
nonCached = max(0, totalPromptTokens - totalCachedTokens)
```

Verified against `curl`, and against the live indicator once the timer bug above
was fixed (742,262 → 743,346 across two polls, matching `curl` at each sample).

### Caveats

- 9Router's skill doc's `/api/usage?period=today` and `Authorization: Bearer` do not
  work. Real route is `/api/usage/stats`; stats auth is `x-9r-cli-token` or a
  dashboard JWT cookie.
- `totalCachedTokens` is cache-**read** only and excludes cache-**creation**, so the
  figure is exact only while `cache_creation_input_tokens` is 0. Currently the sole
  provider is `opencode` and it is always 0. **An Anthropic provider would make this
  over-report.**
- `period=today` resolves to *local* midnight server-side. Never hand-roll UTC bounds:
  on `Asia/Jakarta`, UTC start-of-day catches 489 rows / 16.2M tokens versus 102 rows /
  3.5M locally.

---

## Environment

| Fact | Value |
| --- | --- |
| OS / desktop | Ubuntu 22.04, GNOME Shell 42.9 |
| Session | **X11** |
| Tray host | `ubuntu-appindicators@ubuntu.com` (dpkg) — now **enabled** |
| Timezone | `Asia/Jakarta` |
| 9Router | `http://localhost:20128` |

9Router's own autostart, its server, and `hi@faris` were all left untouched.
9Router's `--tray` flag is hardcoded by upstream at
`src/cli/tray/autostart.js:172` and there is no opt-out; it is harmless now that a
proper tray host exists.

### Two indicators, not one — and why that was kept

The panel shows **two** items left of the wifi/volume/battery cluster, from two
unrelated programs:

| Icon | Owner | Quit means |
| --- | --- | --- |
| `⇅ 567.4k` | `9router-usage.py` (this project) | close the indicator only; server keeps running |
| `⋮` | 9Router's own systray2 tray, via `cli.js --tray` | stop the server |

The second is upstream's, not ours. Merging them was investigated and **declined on
2026-10-11** — the two `Quit` items mean different things, and a single icon doing
double duty would hide that.

The opt-out that does exist, if it is ever wanted again: `isTraySupported()` in
`src/cli/tray/tray.js:33` returns `false` when `DISPLAY` is unset on Linux, and
`DISPLAY` is read nowhere else in the package except the tray's own autostart
click handler (`autostart.js:51`). Prefix the autostart `Exec` with `env -u DISPLAY`
and the `⋮` icon disappears without patching `node_modules` — which matters, because
a patch there is lost on every `npm update`. Full write-up in `README.md`.

---

## Still open

- [ ] `hi@faris` segfault was never root-caused. Prime suspect: its schema is compiled
      user-wide into `~/.local/share/glib-2.0/schemas/` rather than the extension's own
      `schemas/` dir, per its README. **Do not re-enable until investigated** — safe
      mode currently protects against it.
- [ ] No periodic reboot is needed; the counter resets at local midnight on its own.