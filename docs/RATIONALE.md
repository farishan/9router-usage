# Design rationale

Why this is built the way it is. The reasoning is load-bearing: most of it comes
out of a real incident that made the obvious design the wrong one.

For usage, see [`../README.md`](../README.md).

---

## The core decision: render in the shell, work outside it

The obvious way to put a live number in the GNOME top panel is a GNOME Shell
extension — the panel already lives there, so why leave?

**Because work inside the shell process is a different risk class than work
near it.** GNOME Shell is single-threaded and draws every frame. A shell
extension that does I/O every 30 seconds can freeze the entire desktop, and the
only exit is killing the shell — which on a GNOME session means losing the
session. A static label is fine precisely because it does all its work once in
`enable()` and then does nothing forever; dynamic content is not.

So the split is:

- **`ubuntu-appindicators@ubuntu.com`** (the system tray extension) does the drawing.
- **A separate Python process** does the polling.

The shell performs no I/O on our behalf. This indicator cannot segfault
`gnome-shell`, because it is not in `gnome-shell`.

This design was arrived at after a display-flicker incident. Two corrections
below record the parts of the original diagnosis that were wrong.

---

## Corrections to the original diagnosis

Recorded because the wrong version is the one that misleads a later reader.

### 1. The timer was deleting itself — the frozen number

The panel label froze while `curl` showed a different value. Not a rendering
problem and not a network problem: the poll loop had stopped.

```python
GLib.timeout_add_seconds(POLL_SECONDS, refresh, ind, info_items)
```

`refresh()` had no `return` statement, so it returned `None`. In PyGObject,
`None` is `False` is `GLib.SOURCE_REMOVE` — so **the timer deleted itself after
its first fire**. The label reflected the startup poll and nothing after it.

The reflex to "return `False` to keep going" is wrong for GLib, and it is the
opposite of what the name suggests:

| Return value | Meaning |
| --- | --- |
| `GLib.SOURCE_CONTINUE` = `True` | fire again |
| `GLib.SOURCE_REMOVE` = `False` | delete the source |

Measured, PyGObject 3.42.1 / GLib 2.72.4, 1s interval over a 6s window:

```
None  -> fired 1 time     False -> fired 1 time     True -> fired 6 times
```

Every path through `refresh()` now ends in `return GLib.SOURCE_CONTINUE`.

> **The measured version pair matters.** This is the one place the code depends
> on PyGObject's exact coercion of a Python return value into a GLib enum. It was
> measured, not assumed, on the pair listed under *Tested on* in the README. On a
> different PyGObject, re-measure before trusting it.

#### How to see this class of bug without a debugger

The label is the only symptom, so read it straight off D-Bus and watch it move:

```sh
gdbus introspect --session --dest org.kde.StatusNotifierWatcher \
  --object-path /StatusNotifierWatcher   # find ":1.N/.../NotificationItem/9router_usage"
gdbus introspect --session --dest :1.N --object-path /org/ayatana/NotificationItem/9router_usage \
  | grep -E "Title|XAyatanaLabel"
```

And to confirm polls are actually leaving the process, sample `/proc/net/tcp`
(9Router is port `20128` = `0x4EA0`) for 60s; each poll is a new ephemeral
source port. Zero new ports means the timer is dead, whatever the label says.

Note that `strace -p` is unavailable under `kernel.yama.ptrace_scope=1`, which is
the default on Ubuntu. That constraint is worth knowing about *before* you plan
around it.

### 2. `ubuntu-appindicators` is a prerequisite, not the fix

Enabling it was originally listed as the fix for an active bug. It is not.

It is a genuine requirement — without a `StatusNotifierWatcher` on the session
bus, *nothing* can render in a tray — but it was never the fix for anything else.
It was a red herring that happened to coincide with a real requirement. If you
read a troubleshooting step that says "enable it to fix X", the real claim is
only "you need it for anything to appear at all".

### 3. The upstream tray was not the cause of the flicker

The original hypothesis was that 9Router's `systray2` tray created a rogue
override-redirect X window and repainted it over the panel.

**Disproven by observation.** It ran continuously for 30+ minutes with
`ubuntu-appindicators` disabled and produced no flicker. Separately, the Mutter
`needs an allocation` warnings stopped appearing within minutes while it kept
running — so its presence is not *sufficient* to cause the flicker either.

The inference had been plausible but untested when it was made. Worth
recording as a caution: "runs continuously" is not "causes nothing".

---

## Safety rules — enforced in the implementation

1. **Out-of-process.** Own PID; cannot segfault `gnome-shell`.
2. **Never create a `Gtk.Window`.** The only X connection is the one `Gtk.init`
   opens for icon-theme and `Gtk.Menu` support — required because `set_menu()`
   accepts only `Gtk.Menu`, and clicks must go through a D-Bus menu. (An
   X-free variant was written and abandoned: `Gio.DBusMenuModel` is abstract and
   `Indicator` exposes no `activate` signal, so click handling is impossible
   without GTK.)
3. **Never `GtkStatusIcon`** — the API implicated in the flicker.
4. **Never set global GTK state** — no theme name, icon theme, CSS provider,
   `GDK_SCALE`. These force shell-wide repaints.
5. **No shell extension enabled or modified.**
6. **No restart loop.** The autostart entry has no wrapper.
7. **Singleton via `flock`**, not a PID check — see below.
8. **`try/except` around every poll** — an unreachable server yields `—`, not a
   crash.
9. **Quit via exact PID**, never a broad `pkill`.
10. **Autostart delay of 10s** so the shell settles first.

### Why the singleton is an `flock`

The original implementation wrote its PID to `~/.cache/9router-usage.pid` and
decided "is it running?" with `os.kill(pid, 0)`.

That is wrong in a way that is easy to miss: **`kill -0` succeeds for any live
PID**, including one the kernel has recycled to something unrelated. A PID file
left behind by a crash can therefore name a stranger, and the next launch either
refuses forever or — worse — signals a stranger. `install.sh` killing an unrelated
process is the failure this prevents.

`fcntl.flock(fd, LOCK_EX | LOCK_NB)` fixes both halves at once:

- The kernel drops the lock the instant the holder dies, so a crash or hard kill
  **cannot** leave you locked out. There is no stale-lock failure mode.
- The PID inside the file is a *record* for humans and for `install.sh`, never a
  gate.

Two details that are easy to get wrong:

- **Release must not unlink the file.** Unlinking races with a process that has
  already opened and locked the old inode: it holds a lock on a file that no
  longer has a name, while a third process creates a fresh file and locks that
  too. Two instances, two "successful" locks. One inode forever means exactly
  one lock forever.
- **The lock fd is a raw int, not a Python file object.** Nothing garbage-
  collects a raw int, so nothing can close the fd and silently drop the lock.

`install.sh` takes the flock as the liveness signal *and* independently confirms
`/proc/<pid>/cmdline` names this program before signalling anything. Two guards
because this is the one place the script can kill a process that is not ours —
and the second one is what catches an instance predating the flock, which by
definition holds no lock at all.

---

## Data source

```sh
curl http://localhost:20128/api/usage/stats?period=today
```

```
nonCached = max(0, totalPromptTokens - totalCachedTokens)
```

`totalPromptTokens` is cache-inclusive; `totalCachedTokens` is the cache-**read**
subset. This matches 9Router's own definition in `open-sse/providers/pricing.js`.

### Gotchas worth keeping

- **`/api/usage/stats`, not `/api/usage`.** 9Router's skill doc has the wrong
  route, and its `Authorization: Bearer` does not work for stats endpoints —
  stats auth is `x-9r-cli-token` or a dashboard JWT cookie.
- **`period=today` is deliberate.** It resolves to *local* midnight server-side.
  Hand-rolling UTC bounds is not equivalent and not better: measured on
  `Asia/Jakarta`, UTC start-of-day caught 489 rows / 16.2M tokens against 102
  rows / 3.5M locally.
- **Cache-creation tokens are not subtracted.** `totalCachedTokens` counts
  cache-*read* only and excludes cache-*creation*, so the figure is understated
  by the cache-creation volume. Exact while the sole provider is `opencode`
  (which reports `cache_creation_input_tokens: 0`), **wrong once an Anthropic
  provider is added.** Checked 2026-10-11: the stats payload exposes no
  cache-creation field at any level — not top level, nor under `byProvider`,
  `byModel`, `recentRequests`, or `last10Minutes`. All carry only
  `promptTokens / cachedTokens / completionTokens / requests`. Not fixable
  client-side.
- **Stats auth is not used** here because `requireLogin` is off on this
  instance. Turn login on and this client breaks silently and permanently — see
  the P2 item in `../TODO.md`.

---

## Two indicators, not one — and why that was kept

If you see two items left of the wifi/volume/battery cluster, that is expected:

| Icon | Owner | "Quit" means |
| --- | --- | --- |
| `⇅` + token count | this project | close the indicator; **the server keeps running** |
| `⋮` | 9Router's own tray | stop the **server** |

Merging them was investigated and **declined**. The two `Quit` items mean
genuinely different things, and one icon doing double duty would hide that
difference rather than simplify anything.

The opt-out that does exist, if you ever want it: `isTraySupported()` in
`src/cli/tray/tray.js` returns `false` when `DISPLAY` is unset on Linux, and
`DISPLAY` is read nowhere else in the package except the tray's own autostart
click handler. Prefix the autostart `Exec` with `env -u DISPLAY` and the second
icon disappears **without patching `node_modules`** — which is the part that
matters, because a patch there is lost on every `npm update`.

Suppressing it costs you the upstream menu, which would then have to be
re-implemented here: the status line, the auto-start toggle (on Linux just
whether `~/.config/autostart/9router.desktop` exists; disable = unlink it), and
a `Quit` that stops the server rather than just this process.