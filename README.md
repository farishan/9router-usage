# 9router-gtk

Shows **today's total non-cached input token usage** from a local 9Router instance in
the GNOME top panel, next to wifi / volume / battery.

![panel](https://img.shields.io/badge/panel-743.3k-informational)

## Requirements

- 9Router reachable at `http://localhost:20128`
- `gir1.2-ayatanaappindicator3-0.1` and GTK 3 (both present on Ubuntu 22.04)
- **`ubuntu-appindicators@ubuntu.com` must be enabled.** It is the tray host — without
  it nothing can render in the panel at all, and 9Router's own systray2 tray falls
  back to drawing a raw override-redirect X window in the top-right, which flickers.

  ```sh
  gnome-extensions info ubuntu-appindicators@ubuntu.com | grep State   # expect ENABLED
  gnome-extensions enable ubuntu-appindicators@ubuntu.com              # if not
  ```

## Install

```sh
git clone git@github.com:farishan/9router-gtk.git
cd 9router-gtk
./install.sh              # copies to ~/.local/share/9router-gtk + autostart entry
./install.sh --uninstall  # removes both, and stops the indicator if running
```

`install.sh` is the only supported path. It writes `Exec=` with the real install
prefix, so there is no hardcoded username in this repo and the checkout can live
anywhere. There is no `.desktop` file in the repo: `install.sh` generates it,
because a template would either carry a fixed absolute path or need a placeholder
that fails confusingly if copied by hand.

After editing `9router-usage.py`, re-run `./install.sh` and restart the indicator:

```sh
kill $(cat ~/.cache/9router-usage.pid)
```

Log out and back in if you would rather not restart it by hand — the autostart entry
has a 10s delay so the indicator appears after the shell settles.

## Usage

Run from the install prefix (or the checkout, for development):

```sh
python3 9router-usage.py          # run in the foreground
python3 9router-usage.py --once   # print today's non-cached total and exit
```

- **Click the icon** → breakdown (non-cached / cached / output / requests), Open Dashboard, Quit
- Shows `—` when 9Router is unreachable, and recovers on its own
- **Quit only closes this indicator.** It does not stop the 9Router server.

### If the number looks stuck

The label freezes silently rather than dying. Read it straight off D-Bus:

```sh
gdbus introspect --session --dest org.kde.StatusNotifierWatcher \
  --object-path /StatusNotifierWatcher | grep 9router_usage   # gives :1.N
gdbus introspect --session --dest :1.N \
  --object-path /org/ayatana/NotificationItem/9router_usage | grep Title
```

If `Title` stops moving while `curl` does not, the poll timer is dead — see
correction 3 in `plan.md`.

## The two icons in the panel

There are **two** indicators to the left of wifi / volume / battery. This is expected,
not a bug — they come from two different programs:

| Icon (left → right) | Program | Menu |
| --- | --- | --- |
| `⇅` + `743.3k` | **this project** — `9router-usage.py` | Non-cached / Cached / Output / Requests, Open Dashboard, Quit (indicator only) |
| `⋮` (3 dots) | **9Router itself** — `cli.js --tray`, started by `~/.config/autostart/9router.desktop` | `9Router (port 20128)`, Open Dashboard, `✓ Auto-start Enabled`, Quit (stops the server) |

The `⋮` icon is upstream systray2, not ours. Its menu is built in
`9router/src/cli/tray/tray.js` (`buildMenuItems`, menu indexes
`STATUS / DASHBOARD / AUTOSTART / QUIT`).

### If you ever want to merge them into one

9Router's tray has no opt-out flag — `--tray` is what makes it a background process at
all. But `tray.js:33` gates it on `process.env.DISPLAY`:

```js
function isTraySupported() {
  ...
  if (platform === "linux" && !process.env.DISPLAY) return false;
```

`DISPLAY` is read **nowhere else** in the package — the only other hit is
`src/cli/tray/autostart.js:51`, which is inside the tray's own click handler. So
prefixing the autostart `Exec` with `env -u DISPLAY` suppresses the `⋮` icon and
touches nothing else:

```ini
Exec=env -u DISPLAY /path/to/node /path/to/cli.js --tray --skip-update
```

The missing menu items would then be re-implemented in `9router-usage.py`:

- status line — `9Router (port 20128)`, disabled label
- auto-start toggle — `isAutoStartEnabled()` on Linux is just
  `~/.config/autostart/9router.desktop` exists; disable = unlink that file
- quit — would need to stop the server too, not just this process

**This was considered on 2026-10-11 and deliberately left unimplemented.** Two icons
was judged clearer than one icon doing double duty, mainly because their `Quit`
items have genuinely different meanings.

## Autostart

Installed by `install.sh` at `~/.config/autostart/9router-usage.desktop`, pointing at
`~/.local/share/9router-gtk/9router-usage.py`. It has a 10s delay so it starts after
the shell settles, and there is deliberately **no restart wrapper**.

To stop it: `kill $(cat ~/.cache/9router-usage.pid)`. Never `pkill python` —
the PID file plus the singleton lock is what keeps exactly one instance alive.

## How the number is computed

```
nonCached = max(0, totalPromptTokens - totalCachedTokens)
```

from `GET /api/usage/stats?period=today`.

`totalPromptTokens` is cache-inclusive; `totalCachedTokens` is the cache-read subset.
This matches 9Router's own definition in `open-sse/providers/pricing.js`.

### Caveats

- **Cache-creation tokens are not subtracted.** 9Router's `totalCachedTokens` counts
  cache-*read* only and excludes cache-*creation*, so the true definition
  (`prompt − cached − cache_creation`) is understated by the cache-creation volume.
  On this setup the only provider is `opencode` and `cache_creation_input_tokens` is
  always `0`, so the figure is exact here. **If you add an Anthropic provider, this
  will over-report.**
- **`period=today` is used deliberately.** It resolves to *local* midnight server-side.
  Hand-rolling UTC bounds is wrong here — on `Asia/Jakarta` the difference is large
  (UTC start-of-day catches 489 rows / 16.2M tokens vs 102 rows / 3.5M locally).
- The label can lag `curl` by up to 30 seconds; that is the poll interval.
- Stats auth is not used — this instance has `requireLogin` off. The 9Router skill
  doc's `Authorization: Bearer` is not valid for these endpoints.

## Files

| File | Purpose |
| --- | --- |
| `9router-usage.py` | The indicator |
| `install.sh` | Installs / uninstalls the script and generates the autostart entry |
| `plan.md` | Investigation notes, safety rules, and the post-reboot checklist |

## Safety

Deliberately conservative after a previous tray attempt caused screen flicker:

- Out-of-process. It runs in its own PID and cannot segfault `gnome-shell`.
- Never creates a `Gtk.Window`. The only X connection is the one `Gtk.init` opens for
  icon-theme and menu support.
- Never touches global GTK state — no theme name, icon theme, CSS provider or
  `GDK_SCALE`. Those force shell-wide repaints.
- No shell extension is enabled or modified. In particular `hi@faris` is left alone.
- Singleton PID lock, no restart loop, and every network error is caught so the
  process cannot die and blink the icon out of the panel.