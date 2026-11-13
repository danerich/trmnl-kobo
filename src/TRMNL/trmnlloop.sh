#!/bin/sh
# trmnl-kobo v1.0.8 trmnlloop.sh, patched for the Kobo Glo HD (danerich/trmnl-kobo, branch glohd; see glohd/README.md).
# Changes from upstream:
# - Wi-Fi is brought up synchronously: wait for wpa_supplicant to associate,
#   then for a DHCP lease, instead of upstream's background restore plus a
#   blind 8 s + ConnectedGracePeriod sleep. If that fails the radio is
#   power-cycled once and tried again. (Upstream PRs #25/#35 diagnose the same
#   "Wi-Fi not up yet" failures.)
# - Every screen is drawn through draw_screen with ONE rotation, read from
#   config.json "Rotation" (fbdepth native rotation, default 2). Upstream drew
#   errors at -r 0, upside down relative to the TRMNL image.
# - Updates are drawn without the black flash, except the first after start,
#   every "FlashEvery"th image (default 4, about hourly) to clear ghosting, and
#   after an offline banner. An image identical to the one on screen isn't
#   redrawn at all.
# - The Kobo/URL error screen is never shown. A failed cycle keeps the last
#   image and retries after 1, 2, then every 5 minutes; only after 4 failed
#   cycles in a row (about 10 min) does a small "Offline" banner appear.
# - One line per cycle goes to cycles.log next to this script (survives
#   reboots, readable over USB), with Wi-Fi timings and the failure reason.
# - The fallback suspend arms the RTC alarm first (upstream PR #35), so it
#   can't sleep with no wake-up timer.

trmnl_rotation=$(jq -r '.Rotation // 2' config.json 2>/dev/null)
case "$trmnl_rotation" in 0|1|2|3) ;; *) trmnl_rotation=2 ;; esac
trmnl_portrait_rotation=$(jq -r '.PortraitRotation // 1' config.json 2>/dev/null)
case "$trmnl_portrait_rotation" in 0|1|2|3) ;; *) trmnl_portrait_rotation=1 ;; esac
flash_every=$(jq -r '.FlashEvery // 4' config.json 2>/dev/null)
case "$flash_every" in ''|*[!0-9]*|0) flash_every=4 ;; esac
grace=$trmnl_loop_connected_grace_period
case "$grace" in ''|*[!0-9]*) grace=0 ;; esac
wifi_budget=$((20 + grace))     # seconds to wait for association

trmnl_last=/tmp/trmnl.last      # image on screen
trmnl_fails=/tmp/trmnl.fails    # consecutive failed cycles
trmnl_draws=/tmp/trmnl.draws    # images drawn since start (flash cadence)
trmnl_banner=/tmp/trmnl.banner  # exists while the offline banner is shown
trmnl_log=./cycles.log          # persistent, on the Kobo's onboard storage
banner_after=4                  # failed cycles before the banner appears

cycle_start=$(date +%s)
secs() { echo $(($(date +%s) - cycle_start)); }

# note TEXT: one line to the persistent log, kept to the last ~400 lines.
note() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" >>"$trmnl_log"
    if [ "$(wc -l <"$trmnl_log")" -gt 600 ]; then
        tail -n 400 "$trmnl_log" >"$trmnl_log.tmp" && mv -f "$trmnl_log.tmp" "$trmnl_log"
    fi
}

# png_size FILE: "WIDTH HEIGHT" from the PNG or BMP header, empty otherwise.
png_size() {
    dd if="$1" bs=1 count=26 2>/dev/null | od -An -tu1 | awk '
        { for (i = 1; i <= NF; i++) b[n++] = $i }
        END {
            if (n < 26) exit
            if (b[12] == 73 && b[13] == 72 && b[14] == 68 && b[15] == 82) {  # PNG "IHDR", big-endian
                printf "%d %d\n", ((b[16]*256 + b[17])*256 + b[18])*256 + b[19], ((b[20]*256 + b[21])*256 + b[22])*256 + b[23]
            } else if (b[0] == 66 && b[1] == 77) {  # BMP "BM", little-endian; height < 0 = top-down
                w = b[18] + b[19]*256 + b[20]*65536
                h = b[22] + b[23]*256 + b[24]*65536
                if (b[25] >= 128) h = 16777216 - h
                printf "%d %d\n", w, h
            }
        }'
}

# draw_screen FILE MESSAGE MODE: draw FILE (if given) fitted to the screen,
# MESSAGE as an inverted line at the bottom (or centred when there is no
# image). MODE "flash" does a full flashing refresh, anything else updates
# without the flash. Hands the panel back to portrait afterwards.
draw_screen() {
    if [ "$3" = flash ]; then flash=-f; else flash=; fi
    rot=$trmnl_rotation
    size="h=-2,w=0"   # fit to the screen
    if [ -n "$1" ]; then
        dims=$(png_size "$1")
        w=${dims% *}; h=${dims#* }
        if [ -n "$dims" ] && [ "$h" -gt "$w" ]; then
            # Portrait: a model with server rotation (Kindle, rot 90) sends
            # some screens (sleep, setup) pre-rotated. Draw those portrait.
            rot=$trmnl_portrait_rotation
        fi
        # Exact panel size (Kindle PW 7th Gen = 1448x1072): draw 1:1, no
        # resampling. Anything else is scaled to fit.
        if [ "$dims" = "1448 1072" ] || [ "$dims" = "1072 1448" ]; then
            size="w=0,h=0"
        fi
    fi
    ./bin/fbink/fbdepth -r "$rot" >>/tmp/debug.log 2>&1
    if [ -n "$1" ]; then
        ./bin/fbink/fbink -q -c $flash -W GC16 -w \
            -g "file=$1,valign=CENTER,halign=CENTER,$size" >>/tmp/debug.log 2>&1
        [ -n "$2" ] && ./bin/fbink/fbink -q -m -y -2 -h -w " $2 " >>/tmp/debug.log 2>&1
    elif [ -n "$2" ]; then
        ./bin/fbink/fbink -q -c -f -m -M -w "$2" >>/tmp/debug.log 2>&1
    fi
    ./bin/fbink/fbdepth -r -1 >>/tmp/debug.log 2>&1
}

# --- Wi-Fi -----------------------------------------------------------------

wpa_ok() { wpa_cli status 2>/dev/null | grep -q '^wpa_state=COMPLETED'; }

# have_ip: an IPv4 address on any interface but lo (169.254/16 = DHCP failed).
have_ip() {
    ifconfig 2>/dev/null | awk '
        /^[^ \t]/ { iface = $1; sub(/:$/, "", iface) }
        /inet6/   { next }
        /inet/ {
            if (iface == "lo") next
            a = $0; sub(/^.*inet[ \t]*(addr:)?[ \t]*/, "", a); sub(/[^0-9.].*$/, "", a)
            if (a != "" && a != "0.0.0.0" && a !~ /^169\.254\./) { found = 1; exit }
        }
        END { exit !found }'
}

# wait_for CHECK SECONDS: poll CHECK every 0.5 s, 1 on timeout.
wait_for() {
    t=0
    while ! $1; do
        [ "$t" -ge $(($2 * 2)) ] && return 1
        usleep 500000
        t=$((t + 1))
    done
}

# connect_wifi: radio on, wait for association, then a DHCP lease.
# Sets t_assoc/t_ip (seconds into the cycle) or wifi_fail.
connect_wifi() {
    ./scripts/enable-wifi.sh >>/tmp/debug.log 2>&1
    if ! wait_for wpa_ok "$wifi_budget"; then
        ./scripts/log.sh "Not associated after ${wifi_budget}s, reassociating"
        wpa_cli reassociate >>/tmp/debug.log 2>&1
        if ! wait_for wpa_ok 15; then
            wifi_fail="not associated after $(secs)s"
            return 1
        fi
    fi
    t_assoc=$(secs)
    ./scripts/obtain-ip.sh >>/tmp/debug.log 2>&1   # dhcpcd -w: waits for a lease
    if ! wait_for have_ip 15; then
        wifi_fail="associated at ${t_assoc}s but no DHCP lease by $(secs)s"
        return 1
    fi
    t_ip=$(secs)
}

./scripts/ledToggle.sh 8 >>/tmp/debug.log 2>&1

./scripts/log.sh "enable wifi"
wifi_up=1
wifi_tries=1
if ! connect_wifi; then
    ./scripts/log.sh "Wi-Fi failed ($wifi_fail), power-cycling the radio"
    first_fail=$wifi_fail
    ./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1
    sleep 2
    wifi_tries=2
    if ! connect_wifi; then
        wifi_up=0
        wifi_fail="$first_fail; retry: $wifi_fail"
    fi
fi

# --- Battery ----------------------------------------------------------------

if [ -d /sys/class/power_supply/mc13892_bat ]; then
  batteryCapacity=$(cat /sys/class/power_supply/mc13892_bat/capacity)
  batteryStatus=$(cat /sys/class/power_supply/mc13892_bat/status)
elif [ -d /sys/class/power_supply/battery ]; then
  batteryCapacity=$(cat /sys/class/power_supply/battery/capacity)
  batteryStatus=$(cat /sys/class/power_supply/battery/status)
else
  batteryCapacity=50
  batteryStatus="N/A"
  echo "Error: Could not find battery information." >&2
fi

# 4.08 = 90% => 4.19 = 100 %
# 3.12 = 10% => 3.00 = 0 %
trmnl_low_mv=3000
trmnl_high_mv=4195
range_mv=$((trmnl_high_mv - trmnl_low_mv))
voltage_mv=$(( (batteryCapacity * range_mv / 100) + trmnl_low_mv ))
trmnl_fake_voltage="${voltage_mv:0:${#voltage_mv}-3}.${voltage_mv: -3}"

./scripts/log.sh "Battery capacity: ${batteryCapacity}%- Status: ${batteryStatus} - Voltage for API: ${trmnl_fake_voltage}V"

rssi=$(./scripts/getrssi.sh 2>/dev/null)
freq=$(wpa_cli status 2>/dev/null | sed -n 's/^freq=//p')

# --- Fetch ------------------------------------------------------------------

# fetch_display: GET /display into /tmp/trmnl.json and the image into
# /tmp/trmnl.new. On failure returns 1 with fail_reason set.
fetch_display() {
    rm -f /tmp/trmnl.json /tmp/trmnl.new
    if ! curl "${trmnl_apiurl}/display" -L -sS --connect-timeout 15 --max-time 60 \
        -H "ID: $trmnl_id" \
        -H "Access-Token: $trmnl_token" \
        -H "Battery-Voltage: $trmnl_fake_voltage" \
        -H "RSSI: $rssi" \
        -H "FW-Version: ${trmnl_firmware_version}" \
        -o /tmp/trmnl.json 2>/tmp/trmnl.curlerr; then
        fail_reason="display request: $(head -c 120 /tmp/trmnl.curlerr)"; return 1
    fi
    image_url=$(jq -r '.image_url // empty' /tmp/trmnl.json 2>/dev/null)
    if [ -z "$image_url" ]; then
        fail_reason="no image_url: $(head -c 120 /tmp/trmnl.json)"; return 1
    fi
    if ! curl -L -sS --connect-timeout 15 --max-time 120 -o /tmp/trmnl.new "$image_url" 2>/tmp/trmnl.curlerr; then
        fail_reason="image download: $(head -c 120 /tmp/trmnl.curlerr)"; return 1
    fi
    if [ ! -s /tmp/trmnl.new ]; then
        fail_reason="empty image"; return 1
    fi
}

ok=0
attempt=0
if [ "$wifi_up" -eq 1 ]; then
    while [ "$attempt" -lt 3 ]; do
        attempt=$((attempt + 1))
        if fetch_display; then ok=1; break; fi
        ./scripts/log.sh "TRMNL attempt $attempt failed: $fail_reason"
        [ "$attempt" -lt 3 ] && sleep 5s
    done
else
    fail_reason="wifi: $wifi_fail"
fi
fail_reason=$(echo "$fail_reason" | tr '\n' ' ')

# --- Sleep ------------------------------------------------------------------

# suspend_for SECONDS: Wi-Fi off, then rtcwake suspend (upstream logic, plus
# arming the alarm before the fallback suspend).
suspend_for() {
    ./scripts/log.sh "disabling wifi"
    ./scripts/disable-wifi.sh >>/tmp/debug.log 2>&1

    ./scripts/log.sh "Should sleep for $1"
    sleep 5s

    ./scripts/log.sh "Enable suspend state"
    echo 1 >/sys/power/state-extended >>/tmp/debug.log 2>&1
    if [ $? -eq 0 ]; then
        ./scripts/log.sh "Enabled suspend state ok"
    else
        ./scripts/log.sh "Enable suspend state failed"
    fi

    ./scripts/log.sh "Setting up rtcwake alarm"

    start_time=$(date +%s)
    ./bin/busybox_kobo rtcwake -a -s "$1" -m mem >>/tmp/debug.log 2>&1
    if [ $? -eq 0 ]; then
        ./scripts/log.sh "rtcwake ok"
    else
        ./scripts/log.sh "rtcwake failed, will try secondary suspend to memory next"
    fi

    elapsed_time_in_rtcwake=$(($(date +%s) - start_time))

    if [ "$elapsed_time_in_rtcwake" -gt 10 ]; then
        ./scripts/log.sh "rtcwake took more than 10 seconds, skipping suspend to mem in power state"
    else
        ./scripts/log.sh  "rtcwake took ${elapsed_time_in_rtcwake}, writing suspend to mem in power state"
        note "rtcwake returned after ${elapsed_time_in_rtcwake}s, fallback suspend"
        # rtcwake clears the alarm when it returns; without this the fallback
        # suspend has no timer and only wakes on a button press.
        echo 0 >/sys/class/rtc/rtc0/wakealarm 2>>/tmp/debug.log
        echo "+$1" >/sys/class/rtc/rtc0/wakealarm 2>>/tmp/debug.log
        ./scripts/ledToggle.sh 0  >>/tmp/debug.log 2>&1
        sleep 1s
        sync
        sleep 2s
        echo mem >/sys/power/state
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Suspend to mem ok"
        else
            ./scripts/log.sh "Suspend to mem failed"
        fi

        ./scripts/log.sh "Disable suspend state"
        echo 0 >/sys/power/state-extended >>/tmp/debug.log 2>&1
        if [ $? -eq 0 ]; then
            ./scripts/log.sh "Disabled suspend state ok"
        else
            ./scripts/log.sh "Disable suspend state failed"
        fi
    fi
}

# --- Draw -------------------------------------------------------------------

fails=$(cat "$trmnl_fails" 2>/dev/null)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
stats="wifi=${t_assoc:--}s ip=${t_ip:--}s radio_tries=$wifi_tries fetch_tries=$attempt rssi=${rssi:--} freq=${freq:--} bat=${batteryCapacity}%"

if [ "$ok" -eq 1 ]; then
    ./scripts/log.sh "TRMNL fetched $image_url"
    if [ -s "$trmnl_last" ] && [ ! -e "$trmnl_banner" ] &&
        [ "$(md5sum <"$trmnl_last")" = "$(md5sum </tmp/trmnl.new)" ]; then
        drew=unchanged
        rm -f /tmp/trmnl.new
    else
        mv -f /tmp/trmnl.new "$trmnl_last"
        draws=$(cat "$trmnl_draws" 2>/dev/null)
        case "$draws" in ''|*[!0-9]*) draws=0 ;; esac
        draws=$((draws + 1))
        echo "$draws" >"$trmnl_draws"
        if [ -e "$trmnl_banner" ] || [ $(((draws - 1) % flash_every)) -eq 0 ]; then
            drew=flash
        else
            drew=quiet
        fi
        draw_screen "$trmnl_last" "" "$drew"
        rm -f "$trmnl_banner"
    fi
    rm -f "$trmnl_fails"
    [ "$fails" -gt 0 ] && recovered=" recovered_after=$fails" || recovered=
    note "ok $stats draw=$drew$recovered"

    refresh_rate=$(jq -r '.refresh_rate // empty' /tmp/trmnl.json 2>/dev/null)
    case "$refresh_rate" in ''|*[!0-9]*) refresh_rate=900 ;; esac
    suspend_for "$refresh_rate"
else
    fails=$((fails + 1))
    echo "$fails" >"$trmnl_fails"
    case "$fails" in 1) retry=60 ;; 2) retry=120 ;; *) retry=300 ;; esac
    ./scripts/log.sh "TRMNL offline, cycle $fails: $fail_reason"
    note "FAIL cycle=$fails $stats retry=${retry}s reason=$fail_reason"
    # Quiet for short blips; the banner appears once, after a sustained outage.
    if [ "$fails" -eq "$banner_after" ]; then
        if [ -s "$trmnl_last" ]; then
            draw_screen "$trmnl_last" "Offline - retrying every 5 min" flash
        else
            draw_screen "" "TRMNL: can't reach the server. Retrying every 5 min."
        fi
        touch "$trmnl_banner"
    elif [ "$fails" -eq 1 ] && [ ! -s "$trmnl_last" ]; then
        # Nothing on screen yet (just started): say what's happening.
        draw_screen "" "TRMNL: connecting..."
    fi
    suspend_for "$retry"
fi
