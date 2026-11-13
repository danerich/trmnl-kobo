# trmnl-kobo (Kobo Glo HD fork)

Fork of usetrmnl/trmnl-kobo that runs a battery-powered Kobo Glo HD as a TRMNL
display. **Read `glohd/README.md` first**: it covers the trmnl.com model,
every behaviour change, config keys, install, the device log and how to
rebase on a newer upstream.

- Branch `glohd` (default) = upstream tag `v1.0.8` + our changes. `main`
  mirrors upstream. Remote `upstream` = usetrmnl/trmnl-kobo.
- All behaviour changes are in `src/TRMNL/trmnlloop.sh`. Keep the rest of
  `src/` identical to the upstream tag so updates stay a small diff
  (`git diff v1.0.8 glohd -- src`).
- `glohd/install.sh` copies the client onto a USB-mounted Kobo
  (`/Volumes/KOBOeReader`) and edits `.adds/TRMNL/config.json` with python.
  It must never print or overwrite `TrmnlId`/`TrmnlToken`; never commit a
  filled-in config.json.
- The device runs BusyBox `sh`, `awk`, `od`, `dd` plus Kobostuff `curl`/`jq`
  and FBInk. No bash, no GNU options. Check with `sh -n` and keep to POSIX.
- Nothing here can be tested off-device. To diagnose, ask for
  `.adds/TRMNL/cycles.log` (one line per cycle, UTC) before changing code.
- The plugin it mainly shows is `../homestatus` (separate repo). Its
  compact layout targets this device's `screen--md` size class.
