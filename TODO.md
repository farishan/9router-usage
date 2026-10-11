# TODO / Roadmap

Tracking what works, what is known-broken, and what comes next. Ordered by **"what
can bite first"**, not by effort.

Contributions welcome — the top of [Next up](#next-up) is where to start, and
`./verify.sh` is how you check you did not break anything.

---

## What works

Deliberately narrower than "production-ready". This is **v0.1.0**, and the bar was:

> It installs, it runs, it uninstalls, and it does that repeatedly without a human
> intervening — on a machine with this machine's 9Router and these dependency
> versions.

Everything below is done and covered by `./verify.sh` (17 checks, all green):

- [x] Git repo with history; `install.sh` / `--uninstall` with no hardcoded home path
- [x] GLib timer self-destruct fixed — `refresh()` returns `GLib.SOURCE_CONTINUE` on
      every path (`9router-usage.py:139`, `:153`). Returning `None` silently deleted
      the timer after one poll, which is what froze the label. Full story in
      [`docs/RATIONALE.md`](docs/RATIONALE.md).
- [x] Unreachable-server path verified not to crash
- [x] Full round-trip verified by hand: install → run → uninstall → reinstall
- [x] **Singleton is an `flock`, not a check-then-write** — `fcntl.flock(fd, LOCK_EX
      | LOCK_NB)` held for the process lifetime. Closes the launch race *and* the
      stale-PID lockout in one change, because the kernel drops the lock when the
      holder dies. The PID inside is a record, never a gate.
- [x] **`install.sh` no longer kills on a stale PID.** It takes the flock to decide
      liveness *and* independently confirms `/proc/<pid>/cmdline` names this program
      before signalling. Two guards, because this is the one place the script can
      kill a stranger. Covered by `verify.sh` step 3, which points it at a live
      unrelated process and asserts the process survives.
- [x] **An instance predating the `flock` is still recognised and stopped** — it holds
      no lock at all, so only its argv identifies it. `verify.sh` step 4.
- [x] **Re-running `./install.sh` stops the old instance and restarts it** on the new
      code, so *edit → install → see the change* is one command. It only restarts if
      it was already running.
- [x] **`verify.sh` itself** — the round trip as an executable check. 17 assertions
      over 9 steps, every one inside a throwaway `HOME`, so it cannot disturb a real
      installation and is safe to run while the indicator is up.

---

## Next up

Ordered by what bites first. The first two are the ones that turn "it silently
stopped working" into "it told me".

### 1. Log to `~/.cache/9router-usage.log` with a size cap — *highest value*

**Every failure is currently silent.** Any exception becomes `—` and a title
containing `type(exc).__name__` (`9router-usage.py:133-135`). The frozen timer was
found by manually introspecting D-Bus because there was nowhere else to look. That
is not acceptable for something other people now run.

- Log every transition (reachable ↔ unreachable) loudly, each poll quietly, startup always.
- Cap the file size so a long-lived install cannot fill the disk.
- **Delete the log in `--uninstall`**, or "uninstalls cleanly" is a lie.
- This also makes the *Open decision* below actionable — right now a missing icon
  means nothing at all.

### 2. Poll off the main thread

`fetch_usage()` has `timeout=5` (`9router-usage.py:34`) and is called straight from
the `timeout_add_seconds` callback (`9router-usage.py:175`) — i.e. on the GLib main
thread.

Being precise about when this actually bites, because it is not every day:
9Router being *down* returns `ECONNREFUSED` instantly and never waits 5s. The stall
needs 9Router to accept the connection and then stop responding — a hung or
half-dead server. Rare, but it freezes the panel for 5s every 30s while it lasts.

→ Poll in a worker thread and hand the result back with `GLib.idle_add`. Keep all
`Indicator`/`MenuItem` calls on the main thread.

Lower priority than the two above because those break the round trip itself; this
one only degrades it.

### 3. Make the server URL configurable

`BASE_URL` (`9router-usage.py:17`) is hardcoded to `http://localhost:20128`. → Read
`9ROUTER_URL` from the environment, defaulting to today's value.

Cheap, and it is the first thing anyone running this on a non-default port will ask
for.

### 4. Handle 9Router auth, or fail loudly

Today `requireLogin` is off, so stats auth is not sent. Turn login on and this client
breaks **silently and permanently**, because stats auth is `x-9r-cli-token` or a
dashboard JWT (`docs/RATIONALE.md`) and this sends neither.

→ Either support the CLI token, or detect a 401 and say so in the label instead of
rendering the same `—` as "server down". The second is much cheaper and removes
almost all of the confusion.

### 5. Locale-aware number formatting

`format_tokens` (`9router-usage.py:25`) hardcodes an ASCII `.` decimal separator. The
label width also jitters as digits change, which reflows the whole panel cluster.
Fixed-width would settle it.

---

## Known-broken

### Cache-creation tokens — blocked upstream

`README.md` documents that `totalCachedTokens` is cache-**read** only, so the label
over-reports once an Anthropic provider is added.

Checked 2026-10-11: the stats payload exposes **no** cache-creation field at any
level — not top level, nor under `byProvider`, `byModel`, `recentRequests`, or
`last10Minutes`. All carry only `promptTokens / cachedTokens / completionTokens /
requests`.

Cannot be fixed client-side. Needs an upstream field, or accept the caveat and make
it *visible in the UI* — e.g. grey the label when the provider list includes
Anthropic — rather than only in a README nobody rereads.

---

## Deliberate — do not "fix"

These are choices, not oversights, and each is argued in
[`docs/RATIONALE.md`](docs/RATIONALE.md):

- **Out-of-process rendering; never a `Gtk.Window`; never `GtkStatusIcon`; never
  global GTK state.** This is what stopped the flicker.
- **No `pkill`.** Exact PID only.
- **`period=today`**, never hand-rolled UTC bounds.
- **Two icons in the panel.** Their `Quit` items mean genuinely different things,
  which is the reason not to merge them.
- **No restart loop** in the autostart entry.
- **No committed `.desktop` template** — `install.sh` generates it so the install
  prefix is always correct and no username is ever committed.

---

## Open decision

There is **no restart wrapper**, deliberately. The cost is that if the process dies
for any reason the icon silently vanishes from the panel and nothing says why. Two
ways out, both fine:

- **Keep it as is**, and accept that a missing icon means "read the log" — needs
  *Next up #1* first to be usable at all.
- **A systemd user unit** with `Restart=on-failure`, replacing the autostart entry
  entirely. Cleaner than any wrapper, and it would *also* retire the stale-PID
  machinery rather than merely fixing it — but it replaces a two-file install with a
  three-file one, and the original flicker incident argues for the fewest moving
  parts possible.

A real trade, not a strict improvement. **Deciding it properly needs to happen after
#1**, because the systemd option is only clearly better once failures are visible.

---

## Farther out

- No refresh-on-demand; the menu shows whatever the last poll found. A "Refresh now"
  item would also make the log correlate with the label.
- No packaging (deb, AUR, nix). `install.sh` is the whole install story for now.
- No tests beyond `verify.sh` — which is an integration test, not a unit test.
  `format_tokens`, the singleton logic, and the error branches are all untested in
  isolation.