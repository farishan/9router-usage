# TODO

Last rescoped 2026-10-11.

## v0.1.0 — done means

> It installs, it runs, it uninstalls, and it does that repeatedly without a human
> intervening. On *this* machine, with this machine's 9Router, these exact dependency
> versions.

That is the whole bar. It is deliberately narrower than "production-ready" — no longer
"must work on a machine that is not this one". Everything that only matters on other
machines, other locales, or other dependency versions is pushed to the bottom of this
file and is not on the v0.1.0 critical path.

The project is going public, so the expansion path stays open. Nothing below forecloses
it; the later items are additive.

Ordered by "what can bite first", not by effort.

## Done

- [x] Git repo, history exists (9845144, 23ddebe, e860167)
- [x] `install.sh` / `--uninstall`, no hardcoded `/home/faris` path (23ddebe)
- [x] GLib timer self-destruct fixed — `refresh()` returns `GLib.SOURCE_CONTINUE` on
      every path (`9router-usage.py:110`, `:124`)
- [x] Unreachable-server path verified not to crash
- [x] Full round-trip verified by hand on 2026-10-11: install, run, uninstall, reinstall
- [x] **`verify.sh`** — the round-trip as an executable check. 13 assertions over 7
      steps, every one inside a throwaway `HOME`, so it cannot disturb the real
      installation and is safe to run while the indicator is up. Steps needing a
      display or a running 9Router report `SKIP` rather than passing vacuously.
      **13 passed, 0 skipped, 0 failed** on this machine, 2026-10-11.
- [x] **Singleton is an `flock`, not a check-then-write.** `fcntl.flock(fd,
      LOCK_EX | LOCK_NB)` held for the process lifetime. This closed the launch race
      *and* the stale-PID lockout in one change: the kernel drops the lock when the
      holder dies, so the PID file is now a record and never a gate.
- [x] **`install.sh` no longer kills on a stale PID.** It takes the flock to decide
      liveness, and additionally confirms `/proc/<pid>/cmdline` names this program
      before signalling anything. Two independent guards, because this is the one
      place the script can kill a stranger. Covered by `verify.sh` step 3, which
      points it at a live unrelated process and asserts the process survives.
- [x] **Re-running `./install.sh` stops the old instance and restarts it** on the new
      code, so *edit → install → see the change* is one command. It only restarts if
      it was already running. The manual `kill $(cat ...)` step is gone from the
      README, which is what closes the loop — that command was the dangerous one.
- [x] **README corrections:** the install prefix was wrong (`9router-gtk` →
      `9router-usage`, on the two lines a new user reads first), and "singleton lock"
      was an overclaim for what was then a TOCTOU check.

## P0 — the round-trip, repeatable

All four items are done. What each turned into is in the **Done** list above;
`./verify.sh` now covers them mechanically and is what to run after any edit.

## P1 — when it does break, it says nothing

- [ ] **Every failure is silent.** Any exception becomes `—` and a title containing
      `type(exc).__name__` (`9router-usage.py:105-106`). The frozen timer was found by
      manually introspecting D-Bus because there was nowhere else to look. Under the
      new bar this is still in scope, because "runs" is untrustworthy when the only
      symptom is a label that stopped changing.
      → Log to `~/.cache/9router-usage.log` with a size cap. Log every transition
      (server reachable↔unreachable) loudly, each poll quietly, and startup always.
      Also delete the log in `do_uninstall`, or "uninstalls cleanly" is a lie.

- [ ] **Blocking I/O runs on the GLib main thread — but only when 9Router hangs.**
      `fetch_usage()` has `timeout=5` (`9router-usage.py:33`) and is called straight
      from the `timeout_add_seconds` callback (`9router-usage.py:146`).
      Worth being precise about when this actually bites, because it is not every day:
      9Router being *down* returns ECONNREFUSED instantly and never waits 5s. The stall
      needs 9Router to accept the connection and then stop responding — a hung or
      half-dead server. Rare, but it freezes the panel for 5s every 30s while it lasts,
      and it is a bad-day failure rather than a bad-install one.
      → Poll in a worker thread and hand the result back with `GLib.idle_add`. Keep all
      `Indicator`/`MenuItem` calls on the main thread. Lower priority than the three
      above, because those three break the round trip itself; this one only degrades it.

## P2 — when it runs, is it right?

- [ ] **Unreachable, auth-required, malformed JSON, and 9Router-not-running-yet all
      render identically.** Once login is enabled on 9Router this breaks silently and
      permanently, because stats auth is `x-9r-cli-token` or a dashboard JWT
      (`plan.md:173`) and this client sends neither — see the next item. Not a v0.1.0
      problem, since this instance has `requireLogin` off, but it is the first thing
      that will surprise you after any 9Router upgrade.

- [ ] **Blocked upstream: cache-creation tokens.**
      `README.md:139-144` and `plan.md:174-177` document that `totalCachedTokens` is
      cache-*read* only, so the label over-reports once an Anthropic provider is added.
      Checked 2026-10-11: the stats payload exposes **no** cache-creation field at any
      level — not top level, not `byProvider`, `byModel`, `recentRequests`, or
      `last10Minutes`. All of them carry only
      `promptTokens / cachedTokens / completionTokens / requests`.
      → Cannot be fixed client-side. Needs an upstream field, or accept the caveat and
      make it visible in the UI (grey out the label when providers include Anthropic)
      rather than only in the README.

## Before the first push — not v0.1.0 work

None of this is needed to install, run, or uninstall. It is the publish checklist, and
it only becomes urgent the moment this goes public.

- [ ] **No git remote yet.** `git remote -v` is empty, while `README.md:24` already
      advertises `git clone git@github.com:farishan/9router-gtk.git`. Either add the
      remote and push, or the README is a lie on arrival.
- [ ] **No `LICENSE`.** Not optional for a public repo — the default is "all rights
      reserved", which is probably not what you want for something you are publishing
      to be forked.
- [ ] **Repo description and topics.**
- [ ] **Record the tested dependency versions.** PyGObject 3.42.1 / GLib 3.42.1 is the
      combination the `SOURCE_CONTINUE` behaviour was measured on (`plan.md:36-40`).
      Worth documenting as "tested on", and worth a preflight version check later —
      a different PyGObject could plausibly handle the return value differently. Not
      urgent while the only target machine is this one.
- [ ] **Decide `plan.md`'s fate.** It is a machine-state journal, not docs — 6 of its
      9 `hi@faris` mentions are about your own extension's unresolved segfault and the
      safe mode currently protecting you. Fine to publish; also fine to split.
- [ ] **`README.md` has two stale paths.** It says the install prefix is
      `~/.local/share/9router-gtk/` (`README.md:26`, `:120`); `install.sh` actually
      uses `~/.local/share/9router-usage/` (`NAME="9router-usage"`, `install.sh:9`).
      Wrong on the two lines a new user reads first.

## Later — deliberately out of v0.1.0

None of these affect install / run / uninstall on this machine.

- [ ] **Server URL is hardcoded.** `BASE_URL` (`9router-usage.py:16`) is
      `http://localhost:20128` with no override. → Read `9ROUTER_URL` from the
      environment, defaulting to today's value. This is a config feature, not a
      correctness one; it earns its place when the project is used anywhere but here.
- [ ] **No refresh on demand.** 30s poll, and the menu shows whatever the last poll
      found. A "Refresh now" item would also make the log correlate with the label.
- [ ] **`format_tokens` ignores locale** (`9router-usage.py:24`) — `743.3k` with a
      hardcoded `.` decimal. Also the label width jitters as digits change, reflowing
      the panel. Fixed-width would settle it.

## Deliberate — do not "fix"

These are recorded in `plan.md:115-132` and are choices, not oversights:

- Out-of-process rendering; never a `Gtk.Window`; never `GtkStatusIcon`; never global
  GTK state. This is what stopped the flicker.
- No `pkill`. Exact PID only.
- `period=today`, never hand-rolled UTC bounds (`plan.md:178-180`).
- Two icons in the panel. Their `Quit` items mean genuinely different things, which is
  the reason not to merge them (`README.md:112-115`).

## Open decision

There is **no restart wrapper**, deliberately (`plan.md:127`). The cost is that if the
process dies for any reason the icon silently vanishes from the panel and nothing says
why. Two ways out, both fine:

- Keep it as is, and accept that a missing icon means "look at the log" — needs the
  P1 logging first to be usable at all.
- A systemd user unit with `Restart=on-failure`, replacing the autostart entry
  entirely. Cleaner than any wrapper, but adds a moving part, and the original
  flicker incident argues for the fewest moving parts possible.

Worth noting the systemd option would *also* retire the "no restart loop" safety note
in `README.md:170-171` and make the stale-PID item disappear rather than be fixed —
but it replaces a two-file install with a three-file one, so it is a real trade, not a
strict improvement. Revisit after v0.1.0, not before.