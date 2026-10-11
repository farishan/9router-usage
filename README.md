# 9router-usage

A GNOME top-panel indicator showing **today's non-cached input token usage** from a
local **9Router** instance, next to wifi / volume / battery.

```
⇅ 743.3k
```

One Python file, one install script, no build step, no dependencies beyond
PyGObject. It does not modify GNOME, does not touch your shell extensions, and
cannot take down `gnome-shell` — the polling runs in its own process and only the
tray extension draws.

---

## Status

**Working, and mechanically verified.** `./verify.sh` passes 17 checks covering
the whole install → run → uninstall round trip; it is the executable form of
"it works". Run it before you trust anything else on this page.

What "works" means concretely, and what does not yet:

| | |
| --- | --- |
| ✅ | Installs, runs, uninstalls — repeatably, without a human intervening |
| ✅ | Shows a live non-cached token count, updates every 30s |
| ✅ | Survives 9Router being down; shows `—` and recovers on its own |
| ✅ | Refuses to start twice; `flock`, so a crash can never lock out the next launch |
| ✅ | Re-running `install.sh` restarts it on the new code |
| ⚠️ | **Untested on any machine but the one it was built on** — see *Tested on* |
| ⚠️ | **Silent on failure.** Every error becomes a `—` with no log file. Top of the roadmap |
| ⚠️ | Server URL is hardcoded to `http://localhost:20128` |
| ❌ | Cache-*creation* tokens are not subtracted; wrong once you add an Anthropic provider |
| ❌ | Breaks silently if you turn on 9Router's `requireLogin` |

The honest summary: **it works on the machine it was written for, with this
machine's 9Router and these dependency versions.** Everything that only matters on
other machines, other locales, or other versions is tracked and deferred in
[`TODO.md`](TODO.md) rather than quietly assumed to work.

---

## Requirements

- **9Router** reachable at `http://localhost:20128`, with `requireLogin` off.
- **GNOME on X11** with the tray host available.
- Python 3 with **PyGObject** and **GTK 3** (`python3-gi`, `gir1.2-gtk-3.0`).
- **`gir1.2-ayatanaappindicator3-0.1`** — `sudo apt install gir1.2-ayatanaappindicator3-0.1`.
- `flock(1)` from util-linux — present by default on Ubuntu. `install.sh` refuses to
  run without it rather than guess.

### You must have the tray host enabled

```sh
gnome-extensions info ubuntu-appindicators@ubuntu.com | grep State   # expect: State: ENABLED
gnome-extensions enable ubuntu-appindicators@ubuntu.com              # if not
```

Without it there is no `StatusNotifierWatcher` on the session bus and **nothing**
can render in a tray at all — this is a prerequisite, not a fix for anything else.
See [`docs/RATIONALE.md`](docs/RATIONALE.md) for why that distinction matters.

### Tested on

Verified against exactly this combination, which is what the `SOURCE_CONTINUE`
fix in `9router-usage.py` was measured on:

| | |
| --- | --- |
| OS | Ubuntu 22.04.5 LTS, GNOME Shell 42.9, **X11** |
| Python | 3.10.12 |
| PyGObject | 3.42.1 |
| GTK 3 | 3.24.33 |
| GLib | 2.72.4 |

Wayland, newer GNOME, and other PyGObject versions are untested. If the label
freezes while `curl` keeps moving, re-measure the `GLib.SOURCE_CONTINUE` return
convention before assuming anything else is wrong — see
[`docs/RATIONALE.md`](docs/RATIONALE.md#1-the-timer-was-deleting-itself--the-frozen-number).

---

## Install

```sh
git clone git@github.com:farishan/9router-usage.git
cd 9router-usage
./install.sh
```

That copies the script to `~/.local/share/9router-usage/` and writes an autostart
entry at `~/.config/autostart/9router-usage.desktop`.

`install.sh` is the only supported install path, because it generates the
`.desktop` entry with the real install prefix baked in. There is deliberately no
`.desktop` file in this repo: a committed template would either carry a fixed
absolute path or need a placeholder that fails confusingly if someone copies it
by hand. The checkout can live anywhere.

To undo it completely:

```sh
./install.sh --uninstall   # stops the indicator, removes script + autostart entry
```

After editing `9router-usage.py`, just re-run `./install.sh`. It stops the running
instance, copies the new file, and restarts it — so *edit → install → see the
change* is one command. If nothing was running, it says so and leaves it to
autostart at next login.

```sh
./verify.sh   # check the whole install/run/uninstall loop still works
```

---

## Usage

```sh
python3 9router-usage.py          # run in the foreground
python3 9router-usage.py --once   # print today's non-cached total and exit
```

Click the icon for a breakdown (non-cached / cached / output / requests), *Open
Dashboard*, and *Quit*.

**Quit only closes this indicator.** It does not stop the 9Router server. If you
want the server stopped, use 9Router's own tray icon — see *The two icons* below.

### Stopping it by hand

```sh
kill "$(cat ~/.cache/9router-usage.pid)"
```

Never `pkill python` — that takes unrelated things with you.

The PID file is a **record, not a gate**. The indicator holds an exclusive `flock`
on it for its whole lifetime, and that lock — not the PID inside it — is what says
whether something is running. The kernel drops the lock the instant the process
dies, so a crash or a hard kill cannot leave you locked out forever.

(The earlier implementation asked `os.kill(pid, 0)`, which succeeds for *any* live
PID including one the kernel recycled to something unrelated — so a stale file
could lock you out permanently and `install.sh` could kill a stranger. The
rationale is in [`docs/RATIONALE.md`](docs/RATIONALE.md#why-the-singleton-is-an-flock).)

### If the number looks stuck

The label freezes silently rather than dying. Read it straight off D-Bus:

```sh
gdbus introspect --session --dest org.kde.StatusNotifierWatcher \
  --object-path /StatusNotifierWatcher | grep 9router_usage   # gives :1.N
gdbus introspect --session --dest :1.N \
  --object-path /org/ayatana/NotificationItem/9router_usage | grep Title
```

If `Title` stops moving while `curl` does not, the poll timer is dead. This is a
real bug that shipped in an earlier version and is fixed; if you are seeing it,
something about your environment differs from *Tested on* above.

---

## The two icons in the panel

There are **two** indicators to the left of wifi / volume / battery. This is
expected, not a bug — they come from two different programs:

| Icon (left → right) | Program | What "Quit" does |
| --- | --- | --- |
| `⇅` + `743.3k` | **this project** — `9router-usage.py` | closes the indicator; **server keeps running** |
| `⋮` (3 dots) | **9Router itself** — `cli.js --tray` | stops the **server** |

The `⋮` icon is upstream and not ours. Merging them was investigated and
**deliberately declined**: their `Quit` items mean genuinely different things, and
one icon doing double duty would hide that rather than simplify it. If you ever
*do* want one icon, [`docs/RATIONALE.md`](docs/RATIONALE.md) documents a
one-line way to suppress upstream's — including what you'd have to rebuild.

---

## How the number is computed

```
nonCached = max(0, totalPromptTokens - totalCachedTokens)
```

from `GET /api/usage/stats?period=today`. `totalPromptTokens` is cache-inclusive;
`totalCachedTokens` is the cache-**read** subset. This matches 9Router's own
definition in `open-sse/providers/pricing.js`.

### Caveats

- **Cache-creation tokens are not subtracted.** 9Router's `totalCachedTokens`
  counts cache-*read* only and excludes cache-*creation*, so the figure is
  understated by the cache-creation volume. On the machine this was built on the
  only provider is `opencode`, whose `cache_creation_input_tokens` is always `0`,
  so it is exact there. **If you add an Anthropic provider, this will
  over-report.** The stats payload exposes no cache-creation field at any level,
  so this is not fixable client-side.
- **`period=today` is used deliberately.** It resolves to *local* midnight
  server-side. Hand-rolling UTC bounds is not equivalent: on `Asia/Jakarta` the
  difference is large (UTC start-of-day caught 489 rows / 16.2M tokens vs 102
  rows / 3.5M locally).
- The label can lag `curl` by up to 30 seconds; that is the poll interval.
- Stats auth is not used — that assumes `requireLogin` is off. 9Router's skill
  doc's `Authorization: Bearer` is **not** valid for these endpoints; real stats
  auth is `x-9r-cli-token` or a dashboard JWT cookie.

---

## Files

| File | Purpose |
| --- | --- |
| `9router-usage.py` | The indicator |
| `install.sh` | Installs / uninstalls the script and generates the autostart entry |
| `verify.sh` | One-shot check of the install → run → uninstall loop |
| `docs/RATIONALE.md` | Why it is built this way, and the bugs that shaped it |
| `TODO.md` | Known gaps and the roadmap |

## Verify

```sh
./verify.sh
```

17 checks over 9 steps. Everything runs inside a throwaway `HOME`, so it cannot
disturb your real installation and is safe to run while the indicator is up. It
does not reuse `install.sh`'s own helpers — a test that calls the code under test
cannot catch that code being wrong.

It checks that install writes the right files, that the generated `.desktop`
validates, that `--once` returns a number, that a second instance is refused, that
reinstalling stops the old instance, that a stale PID file never kills an
unrelated process, that an instance predating the `flock` is still recognised and
stopped, and that `--uninstall` leaves nothing behind.

Steps that need a display or a running 9Router report `SKIP` rather than passing
vacuously — **a green that means nothing is worse than a red.**

## Safety

Deliberately conservative, after a previous tray attempt caused screen flicker:

- **Out-of-process.** It runs in its own PID and cannot segfault `gnome-shell`.
- **Never creates a `Gtk.Window`.** The only X connection is the one `Gtk.init`
  opens for icon-theme and menu support.
- **Never touches global GTK state** — no theme name, icon theme, CSS provider or
  `GDK_SCALE`. Those force shell-wide repaints.
- **No shell extension is enabled or modified.**
- **No restart loop**, and every network error is caught, so the process cannot
  die and blink the icon out of the panel.
- Singleton is an `flock` held for the process lifetime, so a crash cannot leave
  the next launch locked out.

## License

[GPL-3.0](LICENSE).