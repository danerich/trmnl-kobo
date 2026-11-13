#!/bin/sh
# Install this fork's TRMNL client onto a USB-mounted Kobo.
# Usage: glohd/install.sh [/Volumes/KOBOeReader]
#
# - No .adds/TRMNL yet: copies the whole client (src/TRMNL) across. Then fill
#   in TrmnlId and TrmnlToken in .adds/TRMNL/config.json and run it again.
# - Client already there (v1.0.8): replaces trmnlloop.sh only, backing up the
#   old one, and sets the config keys this setup relies on.
# Safe to re-run. Never prints the TRMNL token or device ID.
set -eu

repo=$(cd "$(dirname "$0")/.." && pwd)
kobo=${1:-/Volumes/KOBOeReader}
dir="$kobo/.adds/TRMNL"

[ -d "$kobo/.kobo" ] || { echo "No Kobo at $kobo. Is it connected and mounted over USB?" >&2; exit 1; }

if [ ! -d "$dir" ]; then
    mkdir -p "$kobo/.adds"
    cp -R "$repo/src/TRMNL" "$dir"
    echo "Copied the client to $dir."
    echo "Install NickelMenu first if you haven't (see readme.md), copy src/nm/TRMNL.ini to .adds/nm/,"
    echo "then fill in TrmnlId and TrmnlToken in $dir/config.json and run this again."
    exit 0
fi

version=$(cat "$dir/version.txt" 2>/dev/null || echo unknown)
if [ "$version" != "1.0.8" ]; then
    echo "Client on the Kobo is version $version; this patch is for 1.0.8." >&2
    echo "See glohd/README.md, 'Updating to a newer upstream'." >&2
    exit 1
fi

# Replace trmnlloop.sh, backing up the previous copy (the first original is kept as .orig).
if ! cmp -s "$repo/src/TRMNL/trmnlloop.sh" "$dir/trmnlloop.sh"; then
    [ -e "$dir/trmnlloop.sh.orig" ] || cp "$dir/trmnlloop.sh" "$dir/trmnlloop.sh.orig"
    cp "$dir/trmnlloop.sh" "$dir/trmnlloop.sh.bak"
    cp "$repo/src/TRMNL/trmnlloop.sh" "$dir/trmnlloop.sh"
    echo "Installed trmnlloop.sh (previous copy in trmnlloop.sh.bak)"
else
    echo "trmnlloop.sh already up to date"
fi

# The cycle log used to be called homestatus.log. Keep its history.
if [ -e "$dir/homestatus.log" ]; then
    cat "$dir/homestatus.log" >>"$dir/cycles.log"
    rm -f "$dir/homestatus.log"
    echo "Moved homestatus.log into cycles.log"
fi

# Settings this setup relies on. Leaves TrmnlId/TrmnlToken untouched.
python3 - "$dir/config.json" <<'EOF'
import json, sys
path = sys.argv[1]
cfg = json.load(open(path))
want = {
    "TrmnlApiUrl": "https://usetrmnl.com/api",
    "ConnectedGracePeriod": 15,  # extra seconds allowed for Wi-Fi to associate
    "Rotation": 2,               # fbdepth rotation for landscape screens
}
changed = [k for k, v in want.items() if cfg.get(k) != v]
for k in changed:
    cfg[k] = want[k]
if changed:
    json.dump(cfg, open(path, "w"), indent=4)
    print("config.json updated:", ", ".join(changed))
else:
    print("config.json already set")
for k in ("TrmnlId", "TrmnlToken"):
    if not cfg.get(k) or cfg[k].startswith("your "):
        print(f"WARNING: {k} is not filled in", file=sys.stderr)
EOF

sync
echo "Done. Eject the Kobo, then start TRMNL from NickelMenu."
