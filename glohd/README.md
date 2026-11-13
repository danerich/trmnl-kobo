# Kobo Glo HD as a TRMNL

This fork of [usetrmnl/trmnl-kobo](https://github.com/usetrmnl/trmnl-kobo) runs a
**Kobo Glo HD** as a battery-powered TRMNL display (BYOD licence). The aim is
for it to behave like a real TRMNL: the right way up every time, quiet updates
without a black flash, and no error screen when Wi-Fi hiccups.

- Branch **`glohd`** (the default here) is upstream tag **v1.0.8** plus one
  rewritten script, [`src/TRMNL/trmnlloop.sh`](../src/TRMNL/trmnlloop.sh), and
  this folder. Everything else is upstream, unchanged.
- `main` mirrors upstream and isn't used.

## Contents

- [Why it needs a patch](#why-it-needs-a-patch)
- [trmnl.com setup](#trmnlcom-setup)
- [What the patched client does](#what-the-patched-client-does)
- [config.json](#configjson)
- [Installing](#installing)
- [Checking Wi-Fi health](#checking-wi-fi-health)
- [Troubleshooting](#troubleshooting)
- [Updating to a newer upstream](#updating-to-a-newer-upstream)

## Why it needs a patch

- **No Glo HD model.** TRMNL has no Glo HD model. The panel is 1448×1072 and
  portrait-native, so a landscape image has to be rotated on the device.
- **Rotation.** Upstream v1.0.8 draws the TRMNL image at `fbdepth` rotation 2
  (in bmp mode) but its own error screen at rotation 0. The two come out 180°
  apart. It can also leave a strip of the previous image after a rotation
  change (upstream PR #27, not released).
- **Wi-Fi.** Upstream switches the radio fully off between refreshes. On waking
  it reconnects in the background and fetches after a fixed 8 s +
  `ConnectedGracePeriod`, whether or not Wi-Fi is up. The Glo HD often takes
  longer, so refreshes failed and showed the Kobo-logo error screen.
  Upstream issue #5 and PRs #25 and #35 report the same thing on other Kobos.
- **Flashing.** Every update did a full black-white flash.

## trmnl.com setup

Set the device model on trmnl.com to **Amazon Kindle PW 7th Gen**
(`amazon_kindle_paperwhite_7th_gen`).

- **Size.** It is 1448×1072, exactly the Glo HD panel, so images are drawn 1:1
  with no rescaling.
- **Greys.** It sends 8-bit greyscale, so greys stay smooth. The panel shows
  16 levels without a dither pattern.
- **Layout.** Plugins see it as `screen--md screen--density-2x` (905×670 CSS px,
  Inter font).
- **Portrait screens.** Its server rotation (`rot=90`) means a few screens
  (the sleep screen, setup) arrive portrait. The client spots these from the
  image header and draws them portrait (see `PortraitRotation` below).

Models tried and not recommended:

- **Kobo Aura HD** (`kobo_aura_hd`) is 1440×1080, 4-bit and dithered. The
  client has to rescale it to 1429×1072. Together that gave a visible halftone
  pattern and scaling artefacts.
- **TRMNL OG** (bmp, 800×480) is far too low resolution for this panel.

## What the patched client does

All of this is in [`src/TRMNL/trmnlloop.sh`](../src/TRMNL/trmnlloop.sh), which
runs once per refresh, called by upstream's `trmnl.sh`.

**Wi-Fi.**
1. Turns the radio on and waits for `wpa_supplicant` to associate (20 s +
   `ConnectedGracePeriod`). If it hasn't, it sends `wpa_cli reassociate` and
   waits 15 s more.
2. Requests a DHCP lease and waits for a real IPv4 address (not 169.254.x.x).
3. If either step fails, it switches the radio off and on and tries once more.

**Fetching.** It asks TRMNL for the display and downloads the image, up to 3
attempts 5 s apart. Wi-Fi is switched off again afterwards, as upstream does.

**Drawing.** Every screen goes through one `draw_screen` function:
- **Rotation.** Landscape images are drawn at `Rotation`, portrait ones at
  `PortraitRotation`.
- **Scaling.** An exactly 1448×1072 image (or 1072×1448) is drawn 1:1.
  Anything else is scaled to fit.
- **Flash.** Updates are drawn without the black flash (GC16 waveform). A full
  flashing refresh happens on the first image after start, every
  `FlashEvery`th image (about hourly at a 15-minute refresh), and when the
  offline banner is cleared. This clears ghosting.
- **Unchanged images.** An image identical to the one on screen isn't redrawn
  at all.
- **Formats.** It reads the size from PNG and BMP headers, so `ImageFormat` no
  longer matters.

**Failures.**
- The Kobo-logo error screen (`bin/error.png`) is never shown.
- A failed cycle leaves the last image up and retries after 1 minute, then
  2 minutes, then every 5 minutes.
- After 4 failed cycles in a row (about 10 minutes) a small "Offline -
  retrying every 5 min" banner appears along the bottom. The next success
  clears it with a full refresh.
- Until then, a plugin that shows its own "Updated HH:MM" time tells you how
  fresh the data is.
- With no image yet (just started), it shows "TRMNL: connecting...".

**Sleep.** Between refreshes it suspends with upstream's `rtcwake`. If
`rtcwake` returns at once and the script falls back to its own suspend, it now
sets the RTC wake alarm first (from upstream PR #35). Without that, the device
would only wake on a button press.

**Log.** One line per cycle goes to `.adds/TRMNL/cycles.log` on the Kobo. See
[Checking Wi-Fi health](#checking-wi-fi-health).

Battery: the device suspends between refreshes, so it runs for weeks on a
charge. The KOReader plugin (`usetrmnl/trmnl-koreader`) handles rotation more
cleanly, but it keeps the device awake, so only use it on USB power.

## config.json

`.adds/TRMNL/config.json` on the Kobo. Upstream keys:

| Key | Value here | Notes |
| --- | --- | --- |
| `TrmnlId` | device MAC | from trmnl.com |
| `TrmnlToken` | API key | from trmnl.com. Never commit it |
| `TrmnlApiUrl` | `https://usetrmnl.com/api` | upstream `main` has since moved to `https://trmnl.app/api` |
| `ConnectedGracePeriod` | `15` | extra seconds allowed for Wi-Fi to associate |
| `ImageFormat` | `bmp` | ignored by the patched draw code |
| `DebugToScreen`, `LoopMaxIteration` | `0` | as upstream |

Keys added by this fork, all optional:

| Key | Default | Notes |
| --- | --- | --- |
| `Rotation` | `2` | `fbdepth` rotation for landscape images. Upside down? Use `0` |
| `PortraitRotation` | `1` | rotation for portrait images (sleep screen). Upside down? Use `3` |
| `FlashEvery` | `4` | full flash every Nth image drawn. Lower it if ghosting builds up |

The installer sets `TrmnlApiUrl`, `ConnectedGracePeriod` and `Rotation`, and
leaves everything else alone.

## Installing

Needs macOS or Linux with `python3`, and the Kobo connected over USB. To get the
USB drive while TRMNL is running, hold the power button to restart the Kobo
into its normal menu, then connect the cable.

**Fresh Kobo.**
1. Install NickelMenu and Kobostuff as in the upstream [readme](../readme.md)
   (copy each `KoboRoot.tgz` to `.kobo/`, eject, let it restart).
2. Copy [`src/nm/TRMNL.ini`](../src/nm/TRMNL.ini) to `.adds/nm/` on the Kobo.
3. Run `glohd/install.sh`. It copies the client to `.adds/TRMNL`.
4. Fill in `TrmnlId` and `TrmnlToken` in `.adds/TRMNL/config.json`.
5. Run `glohd/install.sh` again to set the config keys.
6. Eject, then start TRMNL from NickelMenu.

**Kobo already running upstream v1.0.8 (or an older copy of this patch).**
```sh
glohd/install.sh                       # defaults to /Volumes/KOBOeReader
glohd/install.sh /media/$USER/KOBOeReader
```
- **Script.** It refuses any client version but 1.0.8, then replaces
  `trmnlloop.sh`. The previous copy goes to `trmnlloop.sh.bak`, and the very
  first original is kept as `trmnlloop.sh.orig`.
- **Log.** It moves an old `homestatus.log` into `cycles.log` (the log's
  earlier name).
- **Config.** It sets the config keys above, without touching or printing the
  ID or token.

Then eject and start TRMNL from NickelMenu. To go back to upstream, copy
`trmnlloop.sh.orig` over `trmnlloop.sh`.

## Checking Wi-Fi health

Each cycle appends one line to `.adds/TRMNL/cycles.log`. It keeps the last
~400 lines, with times in UTC. Restart into the normal Kobo menu and connect
USB to read it.

```
2026-11-12T14:00:41Z ok wifi=6s ip=9s radio_tries=1 fetch_tries=1 rssi=-61 freq=2437 bat=87% draw=quiet
2026-11-12T14:15:58Z FAIL cycle=1 wifi=-s ip=-s radio_tries=2 fetch_tries=0 rssi=- freq=- bat=86% retry=60s reason=wifi: ...
```

- **`wifi=` / `ip=`.** Seconds from waking to associating and to getting a DHCP
  lease. Values creeping towards 35 s mean the signal or the router is slow
  to accept the Kobo, not the client.
- **`rssi`.** Below about -75 dBm is weak signal. Move the Kobo or the access
  point.
- **`freq`.** `24xx` is 2.4 GHz, the only band the Glo HD supports. Mesh
  systems or band-steering routers that hide or drop 2.4 GHz clients cause
  "not associated" failures. A separate 2.4 GHz network name fixes that.
- **`radio_tries=2`.** The first attempt failed and switching the radio off
  and on helped. Occasional is fine; every cycle points at the router.
- **`reason=display request: ...` with Wi-Fi up.** Points at DNS or the TRMNL
  server, not the radio.
- **`draw=`.** `flash`, `quiet` or `unchanged` (same image as on screen, not redrawn).
- **`recovered_after=N`.** The first success after N failed cycles.
- **`rtcwake returned after Ns, fallback suspend`.** The normal suspend isn't
  working. Those cycles still wake on time but use more battery.

Upstream's own log (`/tmp/debug.log`) is in RAM and is lost on restart.

## Troubleshooting

| Symptom | Fix |
| --- | --- |
| Everything upside down | `"Rotation": 0` |
| Sleep screen sideways or upside down | `"PortraitRotation": 3` (or 1) |
| Halftone dots or soft text | model on trmnl.com isn't Kindle PW 7th Gen |
| Ghosting between updates | lower `FlashEvery` (e.g. `2`) |
| "Offline" banner | read `cycles.log`, see above |
| Kobo-logo error screen | the patched script isn't installed. Run `glohd/install.sh` |

## Updating to a newer upstream

Upstream releases replace `trmnlloop.sh`. Since v1.0.8, upstream `main` has
added server logging, a forced Wi-Fi connect option, `IgnoreCurlErrors` and the
trmnl.app API URL. To move this fork forward:

1. `git fetch upstream --tags` and read `git diff v1.0.8 <new tag> -- src/TRMNL`.
2. Make a branch from the new tag and bring this fork's changes across. They
   are all in `trmnlloop.sh`:
   - the Wi-Fi functions (`connect_wifi` and friends);
   - `draw_screen` and its size check;
   - the retry and banner logic;
   - the RTC alarm in `suspend_for`;
   - this folder.
   Compare with `git diff v1.0.8 glohd -- src/TRMNL/trmnlloop.sh`.
3. Change the version check in `glohd/install.sh`, test on the device, then
   make that branch the default.

Upstream may also fix some of this itself; check its open PRs first.
