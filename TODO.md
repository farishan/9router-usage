# TODO — getting to production-ready

Written 2026-10-11. Definition of "production-ready" here: it can be installed on a
machine that is not this one, survive a bad day without needing a debugger, and its
numbers can be trusted without reading `plan.md` first.

Ordered by "what can bite first", not by effort.

## Done

- [x] Git repo, history exists (9845144, 23ddebe)
- [x] `install.sh` / `--uninstall`, no hardcoded `/home/faris` path (23ddebe)
- [x] GLib timer self-destruct fixed — `refresh()` returns `GLib.SOURCE_CONTINUE` on
      every path (`9router-usage.py:110`, `:124`)
- [x] Unreachable-server path verified not to crash

## P0 — correctness

- [ ] **Singleton is a check-then-write race, not a lock.**
      `acquire_singleton()` (`9router-usage.py:40`) tests for the file, then writes it.
      Two launches in the same instant both pass and you get two indicators fighting
      over the same name on the StatusNotifierWatcher bus.
      → Replace with `fcntl.flock(fd, LOCK_EX | LOCK_NB)` held open for the process
      lifetime. Fixes this and the next item in one change.

- [ ] **Stale PID file locks you out forever.**
      `os.kill(old, 0)` (`9router-usage.py:46`) succeeds for *any* live PID, including
      one the kernel has since recycled to an unrelated process. The indicator then
      refuses to start with only `already running` on stderr, permanently.
      → With flock the kernel releases the lock when the holder dies, so the PID file
      becomes a record rather than a gate. If it is kept as a gate, validate
      `/proc/<pid>/cmdline` contains `9router-usage.py` before believing it.

- [ ] **Blocking I/O runs on the GLib main thread.**
      `fetch_usage()` has `timeout=5` (`9router-usage.py:33`) and is called straight
      from the `timeout_add_seconds` callback (`9router-usage.py:146`). A hung 9Router
      blocks the main loop for up to 5s, so the menu click stutters or dead-panics —
      the exact "work inside the event loop freezes things" risk that
      `plan.md:105-107` used to reject the shell-extension approach, reintroduced
      in-process.
      → Poll in a worker thread and hand the result back with `GLib.idle_add`.
      Keep all `Indicator`/`MenuItem` calls on the main thread.

## P1 — observability

- [ ] **Every failure is silent.**
      Any exception becomes `—` and a title containing `type(exc).__name__`
      (`9router-usage.py:105-106`). The frozen timer was found by manually
      introspecting D-Bus because there was nowhere to look.
      → Log to `~/.cache/9router-usage.log` with a size cap. Log every transition
      (server reachable↔unreachable) loudly, each poll quietly, and startup always.

- [ ] **No `verify.sh`.**
      One-shot check that the install actually works, in the spirit of `os-sim`'s
      `pnpm verify`. Should cover: `install.sh` → sandboxed `HOME` round-trip →
      `desktop-file-validate` → installed copy `--once` → singleton refuses a second
      instance → `--uninstall` leaves nothing behind. All of that was verified by hand
      on 2026-10-11; none of it is repeatable.

- [ ] **Distinguish the failure modes.**
      Unreachable, auth-required, malformed JSON, and 9Router-not-running-yet all
      render identically. Once login is enabled on 9Router this breaks silently and
      permanently, because stats auth is `x-9r-cli-token` or a dashboard JWT
      (`plan.md:173`) and this client sends neither — see the next item.

## P2 — the numbers

- [ ] **Blocked upstream: cache-creation tokens.**
      `README.md:110-117` and `plan.md:174-177` document that `totalCachedTokens` is
      cache-*read* only, so the label over-reports once an Anthropic provider is added.
      Checked 2026-10-11: the stats payload exposes **no** cache-creation field at any
      level — not top level, not `byProvider`, `byModel`, `recentRequests`, or
      `last10Minutes`. All of them carry only
      `promptTokens / cachedTokens / completionTokens / requests`.
      → Cannot be fixed client-side. Needs an upstream field, or accept the caveat and
      make it visible in the UI (grey out the label when providers include Anthropic)
      rather than only in the README.

- [ ] **Server URL is hardcoded.**
      `BASE_URL` (`9router-usage.py:16`) is `http://localhost:20128` with no override.
      → Read `9ROUTER_URL` from the environment, defaulting to today's value.

## P3 — polish and public-repo prep

- [ ] **No refresh on demand.** 30s poll, and the menu shows whatever the last poll
      found. A "Refresh now" item would also make the log correlate with the label.
- [ ] **`format_tokens` ignores locale** (`9router-usage.py:24`) — `743.3k` with a
      hardcoded `.` decimal. Also the label width jitters as digits change, reflowing
      the panel. Fixed-width would settle it.
- [ ] **Repo metadata for the public push:** description, topics, `LICENSE`.
- [ ] **Decide `plan.md`'s fate.** It is a machine-state journal, not docs — 6 of its
      9 `hi@faris` mentions are about your own extension's unresolved segfault and the
      safe mode currently protecting you. Fine to publish; also fine to split.
- [ ] **Record the tested dependency versions.** PyGObject 3.42.1 / GLib 3.42.1 is the
      combination the SOURCE_CONTINUE behaviour was measured on
      (`plan.md:36-40`). Worth a preflight version check, since a different PyGObject
      could plausibly handle the return value differently.

## Deliberate — do not "fix"

These are recorded in `plan.md:115-132` and are choices, not oversights:

- Out-of-process rendering; never a `Gtk.Window`; never `GtkStatusIcon`; never global
  GTK state. This is what stopped the flicker.
- No `pkill`. Exact PID only.
- `period=today`, never hand-rolled UTC bounds (`plan.md:178-180`).

## Open decision

There is **no restart wrapper**, deliberately (`plan.md:127`). The cost is that if the
process dies for any reason the icon silently vanishes from the panel and nothing says
why. Two ways out, both fine:

- Keep it as is, and accept that a missing icon means "look at the log" — needs the
  P1 logging first to be usable at all.
- A systemd user unit with `Restart=on-failure`, replacing the autostart entry
  entirely. Cleaner than any wrapper, but adds a moving part, and the original
  flicker incident argues for the fewest moving parts possible.